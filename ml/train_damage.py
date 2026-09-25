"""FaultLine damage classifier v1: multi-label EfficientNet-B0.

Runs as a Kaggle kernel (datasets mounted under /kaggle/input) or locally:
    INPUT=/path/to/datasets EPOCHS=1 CAP=64 .venv/bin/python train_damage.py
Outputs to OUT (default /kaggle/working or ./out): model.pt, labels.json, metrics.json, FaultLineDamage.mlpackage.

No-damage = all labels 0 (CODEBRIM background, normal roads, uncracked concrete).
Severity is NOT learned here (no public street-level severity labels); see ml/README.md.
"""
import glob
import json
import os
import random
import time
import xml.etree.ElementTree as ET

import torch
import torch.nn as nn
from PIL import Image
from sklearn.metrics import average_precision_score, f1_score, roc_auc_score
from torch.utils.data import DataLoader, Dataset
from torchvision import models
from torchvision import transforms as T

CLASSES = ["crack", "spalling", "efflorescence", "exposed_rebar", "corrosion", "pothole"]
CODEBRIM = {"Crack": "crack", "Spallation": "spalling", "Efflorescence": "efflorescence",
            "ExposedBars": "exposed_rebar", "CorrosionStain": "corrosion"}
INPUT = os.environ.get("INPUT", "/kaggle/input")
OUT = os.environ.get("OUT", "/kaggle/working" if os.path.isdir("/kaggle/working") else "out")
EPOCHS = int(os.environ.get("EPOCHS", 12))
CAP = int(os.environ.get("CAP", 2500))        # max images per class-folder for folder datasets (and CODEBRIM in smoke tests)
IMG = int(os.environ.get("IMG", 320))
BATCH = int(os.environ.get("BATCH", 48))
IMG_EXT = (".jpg", ".jpeg", ".png")
rng = random.Random(0)
torch.manual_seed(0)


def onehot(*names):
    return [int(c in names) for c in CLASSES]


def split_of(i):
    return "test" if i % 10 == 0 else "val" if i % 10 == 1 else "train"


def dirs_named(name):
    return [r for r, _, _ in os.walk(INPUT, followlinks=True) if os.path.basename(r).lower() == name]


def images_in(dirs):
    return sorted({p for d in dirs for p in glob.glob(os.path.join(d, "*")) if p.lower().endswith(IMG_EXT)})


def codebrim_items():
    """CODEBRIM balanced: {train,val,test}/{background,defects}/*.png + metadata/defects.xml (multi-label)."""
    labels = {}
    for x in glob.glob(os.path.join(INPUT, "**", "metadata", "defects.xml"), recursive=True):
        for d in ET.parse(x).getroot():
            labels[d.get("name")] = onehot(*[CODEBRIM[k] for k in CODEBRIM if d.findtext(k, "0").strip() == "1"])
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
                y = onehot() if kind == "background" else labels.get(os.path.basename(p))
                if y is not None:
                    items.append((p, y, split))
    return items


def folder_items(pos, neg, cls):
    """Binary folder datasets: `pos` folder -> [cls], `neg` folder -> no damage. Deterministic 80/10/10 split."""
    out = []
    for name, y in ((pos, onehot(cls)), (neg, onehot())):
        paths = images_in(dirs_named(name))
        rng.shuffle(paths)
        out += [(p, y, split_of(i)) for i, p in enumerate(paths[:CAP])]
    return out


class Images(Dataset):
    def __init__(self, items, train):
        self.items = items
        norm = T.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])
        self.tf = T.Compose([T.RandomResizedCrop(IMG, scale=(0.4, 1.0)), T.RandomHorizontalFlip(),
                             T.ColorJitter(0.3, 0.3, 0.3, 0.02), T.ToTensor(), norm]) if train else \
            T.Compose([T.Resize(int(IMG * 1.14)), T.CenterCrop(IMG), T.ToTensor(), norm])

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        p, y, _ = self.items[i]
        return self.tf(Image.open(p).convert("RGB")), torch.tensor(y, dtype=torch.float32)


@torch.no_grad()
def predict(model, loader, device):
    model.eval()
    ps, ys = [], []
    for x, y in loader:
        ps.append(torch.sigmoid(model(x.to(device))).float().cpu())
        ys.append(y)
    return torch.cat(ps).numpy(), torch.cat(ys).numpy()


def mean_ap(p, y):
    aps = {c: float(average_precision_score(y[:, i], p[:, i])) for i, c in enumerate(CLASSES) if y[:, i].any()}
    return sum(aps.values()) / max(len(aps), 1), aps


def main():
    os.makedirs(OUT, exist_ok=True)
    items = codebrim_items() + folder_items("potholes", "normal", "pothole") + folder_items("positive", "negative", "crack")
    by = {s: [it for it in items if it[2] == s] for s in ("train", "val", "test")}
    counts = {s: {c: sum(it[1][i] for it in v) for i, c in enumerate(CLASSES)} | {"none": sum(not any(it[1]) for it in v), "total": len(v)}
              for s, v in by.items()}
    print(json.dumps(counts, indent=1))
    assert by["train"] and by["val"] and by["test"], f"empty split; check INPUT={INPUT}"

    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    workers = min(8, os.cpu_count() or 2)
    train_dl = DataLoader(Images(by["train"], True), BATCH, shuffle=True, num_workers=workers, drop_last=True)
    val_dl = DataLoader(Images(by["val"], False), BATCH, num_workers=workers)
    test_dl = DataLoader(Images(by["test"], False), BATCH, num_workers=workers)

    model = models.efficientnet_b0(weights=models.EfficientNet_B0_Weights.IMAGENET1K_V1)
    model.classifier[1] = nn.Linear(model.classifier[1].in_features, len(CLASSES))
    model.to(device)

    pos = torch.tensor([max(counts["train"][c], 1) for c in CLASSES], dtype=torch.float32)
    pos_weight = ((counts["train"]["total"] - pos) / pos).clamp(1, 10).to(device)  # ponytail: static pos_weight; use a balanced sampler if rare classes stay weak
    loss_fn = nn.BCEWithLogitsLoss(pos_weight=pos_weight)
    opt = torch.optim.AdamW(model.parameters(), lr=3e-4, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, 1e-3, total_steps=EPOCHS * len(train_dl), pct_start=0.15)
    scaler = torch.amp.GradScaler(enabled=device == "cuda")

    best, history = -1.0, []
    for epoch in range(EPOCHS):
        model.train()
        t0, total = time.time(), 0.0
        for x, y in train_dl:
            with torch.autocast(device, enabled=device == "cuda"):
                loss = loss_fn(model(x.to(device)), y.to(device))
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
    pv, yv = predict(model, val_dl, device)
    thresholds = {}
    for i, c in enumerate(CLASSES):  # per-class threshold maximizing val F1
        cands = [t / 100 for t in range(5, 96, 5)]
        thresholds[c] = max(cands, key=lambda t: f1_score(yv[:, i], pv[:, i] >= t, zero_division=0)) if yv[:, i].any() else 0.5
    pt, yt = predict(model, test_dl, device)
    tmap, taps = mean_ap(pt, yt)
    any_true, any_score = yt.any(1), pt.max(1)
    metrics = {
        "test_mAP": tmap, "test_AP": taps,
        "test_F1": {c: float(f1_score(yt[:, i], pt[:, i] >= thresholds[c], zero_division=0)) for i, c in enumerate(CLASSES) if yt[:, i].any()},
        "test_any_damage_AUC": float(roc_auc_score(any_true, any_score)) if 0 < any_true.sum() < len(any_true) else None,
        "counts": counts, "history": history,
    }
    json.dump(metrics, open(os.path.join(OUT, "metrics.json"), "w"), indent=1)
    json.dump({"classes": CLASSES, "thresholds": thresholds, "input_size": IMG, "arch": "efficientnet_b0",
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
    mlmodel.short_description = "FaultLine damage classifier v1 (multi-label): " + ", ".join(CLASSES)
    mlmodel.save(os.path.join(OUT, "FaultLineDamage.mlpackage"))
    print("saved FaultLineDamage.mlpackage")


if __name__ == "__main__":
    main()
