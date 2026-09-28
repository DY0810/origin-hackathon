"""Mend damage + material classifier: one multi-label image model -> Core ML.

Runs as a Kaggle kernel (datasets mounted under /kaggle/input) or locally:
    INPUT=/path/to/datasets EPOCHS=1 CAP=64 .venv/bin/python train_damage.py
Config via env vars (Kaggle kernels get them from a generated header; see ml/push_experiment.sh).
Outputs to OUT (default /kaggle/working or ./out): model.pt, labels.json, metrics.json, MendDamage.mlpackage.

Each source declares which classes it actually annotates (`known`). The loss and metrics only use known labels,
so e.g. road photos (labeled only for potholes) don't teach the model "no crack".
Severity is NOT learned here (no public street-level severity labels); see ml/README.md.
"""
import glob
import hashlib
import json
import os
import random
import re
import time
import xml.etree.ElementTree as ET

import torch
import torch.nn as nn
from PIL import Image
from sklearn.metrics import average_precision_score, f1_score, roc_auc_score
from torch.utils.data import DataLoader, Dataset
from torchvision import models
from torchvision import transforms as T

CLASSES = ["crack", "spalling", "efflorescence", "exposed_rebar", "corrosion", "pothole", "leakage", "detachment", "bulge"]
MATERIALS = ["concrete", "asphalt", "brick", "stone", "metal", "tile", "earthen"]
OUTPUTS = CLASSES + ["mat_" + m for m in MATERIALS]  # one sigmoid vector: damage types, then material
CODEBRIM = {"Crack": "crack", "Spallation": "spalling", "Efflorescence": "efflorescence",
            "ExposedBars": "exposed_rebar", "CorrosionStain": "corrosion"}
INPUT = os.environ.get("INPUT", "/kaggle/input")
OUT = os.environ.get("OUT", "/kaggle/working" if os.path.isdir("/kaggle/working") else "out")
ARCH = os.environ.get("ARCH", "efficientnet_b0")  # efficientnet_b0 | efficientnet_v2_s | convnext_tiny
EPOCHS = int(os.environ.get("EPOCHS", 12))
CAP = int(os.environ.get("CAP", 2500))        # max images per class-folder for folder datasets (and CODEBRIM in smoke tests)
IMG = int(os.environ.get("IMG", 320))
BATCH = int(os.environ.get("BATCH", 48))
LR = float(os.environ.get("LR", 1e-3))
IMG_EXT = (".jpg", ".jpeg", ".png")
rng = random.Random(0)
torch.manual_seed(0)


def vec(*names):
    return [int(c in names) for c in OUTPUTS]


ALL = vec(*CLASSES)  # every damage class known


def lab(pos=(), known=ALL, material=None):
    """(y, known) over OUTPUTS. `known` covers damage classes; a material, if given, makes all material outputs known."""
    y, k = vec(*pos), list(known)
    if material:
        y = [a | b for a, b in zip(y, vec("mat_" + material))]
        k = [a | b for a, b in zip(k, vec(*["mat_" + m for m in MATERIALS]))]
    return y, k


def stable_split(key):
    return split_of(int(hashlib.md5(key.encode()).hexdigest(), 16))


def frame_block(stem, block=500):
    """Group consecutive video frames / burst shots so near-duplicates share a split.
    'Hefei1234' -> 'Hefei2'; 'vlcsnap-00123' -> 'vlcsnap-0'; '20250216_164325' -> '20250216_328'; 'vlcsnap_2025-03-16-15h31m12s715' -> 'vlcsnap_2025-03-16-15h31'."""
    t = re.match(r"(.*\d+h\d+)m", stem)  # 'vlcsnap_2025-03-16-15h31m12s715' -> same-minute group
    if t:
        return t[1]
    m = re.match(r"(.*?)(\d+)$", stem)
    return f"{m[1]}{int(m[2]) // block}" if m else stem


def split_of(i):
    return "test" if i % 10 == 0 else "val" if i % 10 == 1 else "train"


def dirs_named(name):
    return [r for r, _, _ in os.walk(INPUT, followlinks=True) if os.path.basename(r).lower() == name]


def images_in(dirs):
    return sorted({p for d in dirs for p in glob.glob(os.path.join(d, "*")) if p.lower().endswith(IMG_EXT)})


def codebrim_items():
    """CODEBRIM balanced: {train,val,test}/{background,defects}/*.png + metadata/defects.xml (multi-label).
    Known: its 5 defect classes + pothole (bridge surfaces have none)."""
    CODEBRIM_KNOWN = vec(*CODEBRIM.values(), "pothole")
    labels = {}
    for x in glob.glob(os.path.join(INPUT, "**", "metadata", "defects.xml"), recursive=True):
        for d in ET.parse(x).getroot():
            labels[d.get("name")] = [CODEBRIM[k] for k in CODEBRIM if d.findtext(k, "0").strip() == "1"]
    items, seen = [], set()
    for split in ("train", "val", "test"):
        for kind in ("background", "defects"):
            paths = glob.glob(os.path.join(INPUT, "**", "classification_dataset_balanced", split, kind, "*.png"), recursive=True)
            paths = sorted(paths)[: CAP if os.environ.get("CAP") else None]
            for p in paths:
                key = (split, kind, os.path.basename(p))
                if key in seen:
                    continue
                seen.add(key)
                pos = [] if kind == "background" else labels.get(os.path.basename(p))
                if pos is not None:
                    items.append((p, None, *lab(pos, CODEBRIM_KNOWN, "concrete"), split))
    return items


def folder_items(pos, neg, cls, known, material=None):
    """Binary folder datasets: `pos` folder -> [cls], `neg` folder (optional) -> none of `known`. Deterministic 80/10/10 split."""
    out = []
    for name, p_cls in ((pos, [cls]), (neg, [])):
        paths = images_in(dirs_named(name)) if name else []
        rng.shuffle(paths)
        out += [(p, None, *lab(p_cls, known, material), split_of(i)) for i, p in enumerate(paths[:CAP])]
    return out


def read_yolo(txt, names):
    """[(class_or_None, cx, cy, w, h)] from a YOLO txt; unknown ids map to None (kept as hard negatives)."""
    boxes = []
    for line in open(txt):
        t = line.split()
        if len(t) == 5:
            boxes.append((names.get(int(float(t[0]))), *map(float, t[1:])))
    return boxes


def square(cx, cy, w, h, W, H, pad=1.25, min_px=64):
    side = max(w * W, h * H) * pad
    side = min(max(side, min_px), W, H)
    x0 = min(max(cx * W - side / 2, 0), W - side)
    y0 = min(max(cy * H - side / 2, 0), H - side)
    return (x0, y0, x0 + side, y0 + side)


def inside(b, crop, W, H):
    """Fraction of YOLO box b's area that lies inside pixel crop."""
    _, cx, cy, w, h = b
    bx0, by0, bx1, by1 = (cx - w / 2) * W, (cy - h / 2) * H, (cx + w / 2) * W, (cy + h / 2) * H
    ix = max(0, min(bx1, crop[2]) - max(bx0, crop[0]))
    iy = max(0, min(by1, crop[3]) - max(by0, crop[1]))
    return ix * iy / max((bx1 - bx0) * (by1 - by0), 1e-6)


def yolo_crop_items(img_dir, lbl_dir, names, known, material=None, negatives=1):
    """Square crops around each box, labeled with every box >=50% inside the crop; plus `negatives`
    random box-free crops per image. Split by source image so crops of one photo never straddle splits."""
    out, per_class = [], {}
    for txt in sorted(glob.glob(os.path.join(lbl_dir, "*.txt"))):
        stem = os.path.splitext(os.path.basename(txt))[0]
        img = next((os.path.join(img_dir, stem + e) for e in (".jpg", ".png", ".jpeg", ".JPG") if os.path.exists(os.path.join(img_dir, stem + e))), None)
        boxes = read_yolo(txt, names)
        if not img or not boxes:
            continue
        W, H = Image.open(img).size
        split = stable_split(frame_block(stem))
        for b in boxes:
            key = b[0] or "hard_negative"  # e.g. manholes: look like potholes, aren't damage
            if per_class.get(key, 0) >= CAP:
                continue
            crop = square(*b[1:], W, H)
            pos = sorted({o[0] for o in boxes if o[0] and inside(o, crop, W, H) >= 0.5})
            per_class[key] = per_class.get(key, 0) + 1
            out.append((img, crop, *lab(pos, known, material), split))
        for _ in range(negatives):
            for _try in range(10):
                side = 0.35 * min(W, H)
                x0, y0 = rng.uniform(0, W - side), rng.uniform(0, H - side)
                crop = (x0, y0, x0 + side, y0 + side)
                if all(inside(o, crop, W, H) == 0 for o in boxes):
                    out.append((img, crop, *lab([], known, material), split))
                    break
    return out


def sibling(name, sib):
    return [os.path.join(os.path.dirname(d), sib) for d in dirs_named(name)]


def mbdd_items():
    """MBDD2025 drone facade photos (JPEGImages/ + Labels/ YOLO). 0 crack, 1 leakage, 2 abscission, 3 corrosion, 4 bulge."""
    names = {0: "crack", 1: "leakage", 2: "detachment", 3: "corrosion", 4: "bulge"}
    return [it for d in dirs_named("jpegimages") for it in
            yolo_crop_items(d, os.path.join(os.path.dirname(d), "Labels"), names, vec(*names.values()))]


def rome_items():
    """Rome road damage (data/images + data/labels-YOLO). 0 pothole, 1 crack, 2 manhole (hard negative)."""
    return [it for d in dirs_named("labels-yolo") for it in
            yolo_crop_items(os.path.join(os.path.dirname(d), "images"), d, {0: "pothole", 1: "crack"}, vec("pothole", "crack"), "asphalt")]


def wall_items():
    """Crack_Hole_Normal_Dataset: images/{train,test} + labels/{train,test} YOLO; 0 normal, 1 crack, 2 hole (ignored).
    Image-level labels (patches are close-ups)."""
    out = []
    for root in dirs_named("crack_hole_normal_dataset"):
        for folder in ("train", "test"):
            for i, img in enumerate(images_in([os.path.join(root, "images", folder)])):
                txt = os.path.join(root, "labels", folder, os.path.splitext(os.path.basename(img))[0] + ".txt")
                if not os.path.exists(txt):
                    continue
                pos = {c for c, *_ in read_yolo(txt, {1: "crack"}) if c}  # holes (id 2) aren't spalling; left unlabeled
                split = "test" if folder == "test" else ("val" if i % 9 == 0 else "train")
                out.append((img, None, *lab(pos, vec("crack", "pothole"), "concrete"), split))
    return out


def all_items():
    return (codebrim_items()
            # road photos: pothole labeled; road cracks not annotated -> crack unknown
            + folder_items("potholes", "normal", "pothole", vec(*[c for c in CLASSES if c != "crack"]), "asphalt")
            # clean/cracked concrete close-ups: every damage class annotated (clean patches have no defects)
            + folder_items("positive", "negative", "crack", ALL, "concrete")
            # historic walls, crack-only positives per material
            + folder_items("crack brick", None, "crack", vec("crack"), "brick")
            + folder_items("crack stone", None, "crack", vec("crack"), "stone")
            + folder_items("crack cob", None, "crack", vec("crack"), "earthen")
            + folder_items("crack tile", None, "crack", vec("crack"), "tile")
            # rusted iron/steel, positives only (the dataset's negatives are stock product photos: shortcut risk)
            + folder_items("corrosion", None, "corrosion", vec("corrosion"), "metal")
            + mbdd_items() + rome_items() + wall_items())


class Images(Dataset):
    def __init__(self, items, train):
        self.items = items
        norm = T.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])
        self.tf = T.Compose([T.RandomResizedCrop(IMG, scale=(0.35, 1.0)), T.RandomHorizontalFlip(), T.RandomVerticalFlip(0.2),
                             T.TrivialAugmentWide(), T.ToTensor(), norm, T.RandomErasing(0.2)]) if train else \
            T.Compose([T.Resize(int(IMG * 1.14)), T.CenterCrop(IMG), T.ToTensor(), norm])

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        p, crop, y, known, _ = self.items[i]
        im = Image.open(p).convert("RGB")
        if crop:
            im = im.crop(tuple(round(v) for v in crop))
        return self.tf(im), torch.tensor(y, dtype=torch.float32), torch.tensor(known, dtype=torch.float32)


def build_model():
    if ARCH == "convnext_tiny":
        m = models.convnext_tiny(weights=models.ConvNeXt_Tiny_Weights.IMAGENET1K_V1)
        m.classifier[2] = nn.Linear(m.classifier[2].in_features, len(OUTPUTS))
    elif ARCH == "efficientnet_v2_s":
        m = models.efficientnet_v2_s(weights=models.EfficientNet_V2_S_Weights.IMAGENET1K_V1)
        m.classifier[1] = nn.Linear(m.classifier[1].in_features, len(OUTPUTS))
    else:
        m = models.efficientnet_b0(weights=models.EfficientNet_B0_Weights.IMAGENET1K_V1)
        m.classifier[1] = nn.Linear(m.classifier[1].in_features, len(OUTPUTS))
    return m


@torch.no_grad()
def predict(model, loader, device):
    """Sigmoid probabilities with horizontal-flip test-time augmentation."""
    model.eval()
    ps, ys, ks = [], [], []
    for x, y, k in loader:
        x = x.to(device)
        ps.append(((torch.sigmoid(model(x)) + torch.sigmoid(model(x.flip(3)))) / 2).float().cpu())
        ys.append(y)
        ks.append(k)
    return torch.cat(ps).numpy(), torch.cat(ys).numpy(), torch.cat(ks).numpy().astype(bool)


def per_class(p, y, k, fn):
    """Apply fn(y_true, y_score) per class over rows where that class is known and both outcomes are present."""
    out = {}
    for i, c in enumerate(OUTPUTS):
        yi, pi = y[k[:, i], i], p[k[:, i], i]
        if 0 < yi.sum() < len(yi):
            out[c] = float(fn(yi, pi))
    return out


def mean_ap(p, y, k):
    """Mean AP over damage classes (materials reported but not used for model selection)."""
    aps = per_class(p, y, k, average_precision_score)
    dmg = [v for c, v in aps.items() if c in CLASSES]
    return sum(dmg) / max(len(dmg), 1), aps


def main():
    os.makedirs(OUT, exist_ok=True)
    items = all_items()
    by = {s: [it for it in items if it[4] == s] for s in ("train", "val", "test")}
    counts = {s: {c: sum(it[2][i] for it in v) for i, c in enumerate(OUTPUTS)} | {"no_damage": sum(not any(it[2][:len(CLASSES)]) and all(it[3][:len(CLASSES)]) for it in v), "total": len(v)}
              for s, v in by.items()}
    print(ARCH, IMG, EPOCHS, json.dumps(counts))
    assert by["train"] and by["val"] and by["test"], f"empty split; check INPUT={INPUT}"

    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    workers = min(8, os.cpu_count() or 2)
    train_dl = DataLoader(Images(by["train"], True), BATCH, shuffle=True, num_workers=workers, drop_last=True, persistent_workers=True)
    val_dl = DataLoader(Images(by["val"], False), BATCH, num_workers=workers)
    test_dl = DataLoader(Images(by["test"], False), BATCH, num_workers=workers)

    model = build_model().to(device)
    known = torch.tensor([it[3] for it in by["train"]], dtype=torch.float32)
    ys = torch.tensor([it[2] for it in by["train"]], dtype=torch.float32)
    pos, neg = (ys * known).sum(0).clamp(min=1), ((1 - ys) * known).sum(0)
    pos_weight = (neg / pos).clamp(1, 10).to(device)  # ponytail: static pos_weight; balanced sampler if rare classes stay weak
    bce = nn.BCEWithLogitsLoss(pos_weight=pos_weight, reduction="none")
    opt = torch.optim.AdamW(model.parameters(), lr=LR / 3, weight_decay=0.05 if ARCH == "convnext_tiny" else 1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, LR, total_steps=EPOCHS * len(train_dl), pct_start=0.1)
    use_amp = device == "cuda"
    scaler = torch.amp.GradScaler(enabled=use_amp)

    best, history = -1.0, []
    for epoch in range(EPOCHS):
        model.train()
        t0, total = time.time(), 0.0
        for x, y, k in train_dl:
            x, y, k = x.to(device), y.to(device), k.to(device)
            with torch.autocast(device, enabled=use_amp):
                loss = (bce(model(x).float(), y) * k).sum() / k.sum().clamp(min=1)
            opt.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(opt)
            scaler.update()
            sched.step()
            total += loss.item()
        vmap, vaps = mean_ap(*predict(model, val_dl, device))
        history.append({"epoch": epoch + 1, "loss": total / len(train_dl), "val_mAP": vmap, "val_AP": vaps, "sec": round(time.time() - t0)})
        print(json.dumps(history[-1]), flush=True)
        if vmap > best:
            best = vmap
            torch.save(model.state_dict(), os.path.join(OUT, "model.pt"))

    model.load_state_dict(torch.load(os.path.join(OUT, "model.pt"), map_location=device))
    pv, yv, kv = predict(model, val_dl, device)
    thresholds = {}
    for i, c in enumerate(OUTPUTS):  # per-class threshold maximizing val F1 (known rows only)
        yi, pi = yv[kv[:, i], i], pv[kv[:, i], i]
        thresholds[c] = max((t / 100 for t in range(5, 96, 5)), key=lambda t: f1_score(yi, pi >= t, zero_division=0)) if yi.any() else 0.5
    pt, yt, kt = predict(model, test_dl, device)
    tmap, taps = mean_ap(pt, yt, kt)
    f1s = {c: float(f1_score(yt[kt[:, i], i], pt[kt[:, i], i] >= thresholds[c], zero_division=0)) for i, c in enumerate(OUTPUTS) if yt[kt[:, i], i].any()}
    nd = len(CLASSES)
    full = kt[:, :nd].all(1)  # rows where "no damage" is actually known
    any_true, any_score = yt[full, :nd].any(1), pt[full, :nd].max(1)
    metrics = {
        "arch": ARCH, "img": IMG, "epochs": EPOCHS,
        "test_mAP": tmap, "test_AP": taps, "test_F1": f1s,
        "test_any_damage_AUC": float(roc_auc_score(any_true, any_score)) if 0 < any_true.sum() < len(any_true) else None,
        "counts": counts, "history": history,
    }
    json.dump(metrics, open(os.path.join(OUT, "metrics.json"), "w"), indent=1)
    json.dump({"classes": CLASSES, "materials": MATERIALS, "outputs": OUTPUTS, "thresholds": thresholds, "input_size": IMG, "arch": ARCH,
               "mean": [0.485, 0.456, 0.406], "std": [0.229, 0.224, 0.225]}, open(os.path.join(OUT, "labels.json"), "w"), indent=1)
    print("TEST", json.dumps({k: metrics[k] for k in ("test_mAP", "test_AP", "test_F1", "test_any_damage_AUC")}, indent=1))

    export_coreml(model.cpu().eval())


def export_coreml(model):
    """Core ML package for the iOS on-device prefilter. Best effort: needs `coremltools` installed."""
    try:
        if os.path.isdir("/kaggle/working"):
            import subprocess
            subprocess.run(["pip", "install", "-q", "coremltools"], check=False)
        import coremltools as ct
    except ImportError:
        print("coremltools not installed; skipped .mlpackage export (rerun export_coreml locally on model.pt)")
        return
    wrapped = nn.Sequential(model, nn.Sigmoid()).eval()
    traced = torch.jit.trace(wrapped, torch.rand(1, 3, IMG, IMG))
    std = 0.226  # Core ML ImageType takes one scale; mean of ImageNet stds
    mlmodel = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                         inputs=[ct.ImageType(name="image", shape=(1, 3, IMG, IMG), scale=1 / (255 * std),
                                              bias=[-0.485 / std, -0.456 / std, -0.406 / std])],
                         outputs=[ct.TensorType(name="probabilities")])
    mlmodel.short_description = f"Mend damage + material classifier ({ARCH}, multi-label sigmoid): " + ", ".join(OUTPUTS)
    mlmodel.save(os.path.join(OUT, "MendDamage.mlpackage"))
    print("saved MendDamage.mlpackage")


if __name__ == "__main__":
    main()
