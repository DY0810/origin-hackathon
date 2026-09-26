"""FaultLine damage detector: boxes per issue (YOLO) -> Core ML with NMS.

Runs as a Kaggle kernel (datasets mounted under /kaggle/input) or locally:
    INPUT=/path/to/datasets EPOCHS=1 CAP=50 RDD_CAP=50 python train_detector.py
Push: kaggle kernels push -p ml/detector --accelerator NvidiaTeslaT4
Outputs to OUT (default /kaggle/working or ./out): best.pt, metrics.json, detector_labels.json, FaultLineDetector.mlpackage.

Sources (all YOLO-format boxes):
- MBDD2025 drone facades (JPEGImages/ + Labels/): crack, leakage, detachment, corrosion, bulge.
- Rome road damage (images/ + labels-YOLO/): pothole, crack; manholes dropped.
- RDD2022 YOLO (train|val|test/images|labels): D00/D10/D20 -> crack, D40 -> pothole; its own split, capped by RDD_CAP.
Splits for MBDD/Rome use frame_block() so near-duplicate video frames never straddle train/test (ml/README.md v4).
The wall crack/hole set is left out: its images are tiny close-up patches, useless for localization.
"""
import glob
import hashlib
import json
import os
import random
import re
import subprocess
import sys

CLASSES = ["crack", "pothole", "corrosion", "leakage", "detachment", "bulge"]
INPUT = os.environ.get("INPUT", "/kaggle/input")
OUT = os.environ.get("OUT", "/kaggle/working" if os.path.isdir("/kaggle/working") else "out")
MODEL = os.environ.get("MODEL", "yolo11n.pt")
EPOCHS = int(os.environ.get("EPOCHS", 80))
HOURS = float(os.environ.get("HOURS", 9))      # Ultralytics stops at this wall-clock budget (Kaggle GPU sessions cap at 12 h)
IMG = int(os.environ.get("IMG", 640))
BATCH = int(os.environ.get("BATCH", 32))
CAP = int(os.environ.get("CAP", 0))            # max images per source (0 = all); for smoke tests
RDD_CAP = int(os.environ.get("RDD_CAP", 8000))  # RDD2022 is ~38k images; a capped slice keeps the run inside HOURS
IMG_EXT = (".jpg", ".jpeg", ".png")
DATA = os.path.join(OUT, "yolo")
rng = random.Random(0)


# --- keep in sync with ml/train_damage.py (Kaggle script kernels are single files, so no import) ---
def stable_split(key):
    return split_of(int(hashlib.md5(key.encode()).hexdigest(), 16))


def frame_block(stem, block=500):
    """Group consecutive video frames / burst shots so near-duplicates share a split."""
    t = re.match(r"(.*\d+h\d+)m", stem)
    if t:
        return t[1]
    m = re.match(r"(.*?)(\d+)$", stem)
    return f"{m[1]}{int(m[2]) // block}" if m else stem


def split_of(i):
    return "test" if i % 10 == 0 else "val" if i % 10 == 1 else "train"


def dirs_named(name):
    return [r for r, _, _ in os.walk(INPUT, followlinks=True) if os.path.basename(r).lower() == name]
# --- end sync ---


def image_for(img_dir, stem):
    return next((os.path.join(img_dir, stem + e) for e in (".jpg", ".png", ".jpeg", ".JPG")
                 if os.path.exists(os.path.join(img_dir, stem + e))), None)


def remap(txt, ids):
    """YOLO lines with source class ids mapped to CLASSES indices; unmapped classes (e.g. manholes) dropped."""
    out = []
    for line in open(txt):
        t = line.split()
        if len(t) == 5 and int(float(t[0])) in ids:
            out.append(f"{CLASSES.index(ids[int(float(t[0]))])} {' '.join(t[1:])}")
    return out


def pairs(img_dir, lbl_dir):
    return [(image_for(img_dir, os.path.splitext(os.path.basename(t))[0]), t)
            for t in sorted(glob.glob(os.path.join(lbl_dir, "*.txt")))]


def add(source, img, lines, split, counts):
    """Symlink the image into DATA/images/<split>/ and write its remapped labels (empty file = background image)."""
    name = f"{source}_{os.path.basename(img)}"
    os.symlink(img, os.path.join(DATA, "images", split, name))
    with open(os.path.join(DATA, "labels", split, os.path.splitext(name)[0] + ".txt"), "w") as f:
        f.write("\n".join(lines))
    for line in lines:
        counts[split][CLASSES[int(line.split()[0])]] += 1


def build():
    counts = {s: {c: 0 for c in CLASSES} for s in ("train", "val", "test")}
    for s in counts:
        os.makedirs(os.path.join(DATA, "images", s), exist_ok=True)
        os.makedirs(os.path.join(DATA, "labels", s), exist_ok=True)
    sources = []
    mbdd = {0: "crack", 1: "leakage", 2: "detachment", 3: "corrosion", 4: "bulge"}
    for d in dirs_named("jpegimages"):
        sources.append(("mbdd", pairs(d, os.path.join(os.path.dirname(d), "Labels")), mbdd, None))
    for d in dirs_named("labels-yolo"):
        sources.append(("rome", pairs(os.path.join(os.path.dirname(d), "images"), d), {0: "pothole", 1: "crack"}, None))
    rdd = {0: "crack", 1: "crack", 2: "crack", 3: "pothole"}
    for y in glob.glob(os.path.join(INPUT, "**", "data.yaml"), recursive=True):
        if "Longitudinal" not in open(y).read():
            continue
        root = os.path.dirname(y)
        for s in ("train", "val", "test"):
            p = pairs(os.path.join(root, s, "images"), os.path.join(root, s, "labels"))
            rng.shuffle(p)
            sources.append(("rdd", p[: max(1, RDD_CAP * {"train": 8, "val": 1, "test": 1}[s] // 10)], rdd, s))
    for source, items, ids, fixed_split in sources:
        for img, txt in items[: CAP or None]:
            if img:
                stem = os.path.splitext(os.path.basename(img))[0]
                add(source, img, remap(txt, ids), fixed_split or stable_split(frame_block(stem)), counts)
    with open(os.path.join(DATA, "data.yaml"), "w") as f:
        f.write(f"path: {DATA}\ntrain: images/train\nval: images/val\ntest: images/test\nnames: {json.dumps(CLASSES)}\n")
    print("boxes per split:", json.dumps(counts), flush=True)
    return counts


def main():
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "ultralytics", "coremltools"], check=True)
    from ultralytics import YOLO

    counts = build()
    model = YOLO(MODEL)
    model.train(data=os.path.join(DATA, "data.yaml"), epochs=EPOCHS, time=HOURS, imgsz=IMG, batch=BATCH,
                project=OUT, name="run", exist_ok=True, seed=0, plots=False)
    best = YOLO(os.path.join(OUT, "run", "weights", "best.pt"))
    r = best.val(data=os.path.join(DATA, "data.yaml"), split="test", imgsz=IMG, plots=False)
    per_class = {CLASSES[c]: {"mAP50": round(float(r.box.ap50[i]), 3), "mAP50_95": round(float(r.box.ap[i]), 3),
                              "precision": round(float(r.box.p[i]), 3), "recall": round(float(r.box.r[i]), 3),
                              "test_boxes": counts["test"][CLASSES[c]]}
                 for i, c in enumerate(r.box.ap_class_index)}
    metrics = {"model": MODEL, "imgsz": IMG, "epochs_budget": EPOCHS, "hours_budget": HOURS,
               "test_mAP50": round(float(r.box.map50), 3), "test_mAP50_95": round(float(r.box.map), 3),
               "per_class": per_class, "boxes": counts}
    json.dump(metrics, open(os.path.join(OUT, "metrics.json"), "w"), indent=2)
    print(json.dumps(metrics, indent=2), flush=True)
    # Starting per-class confidence floor; the app hides classes whose test AP says they don't work (ml/README.md).
    json.dump({"classes": CLASSES, "input_size": IMG, "thresholds": {c: 0.35 for c in CLASSES}},
              open(os.path.join(OUT, "detector_labels.json"), "w"), indent=2)
    path = best.export(format="coreml", nms=True, imgsz=IMG)
    os.replace(path, os.path.join(OUT, "FaultLineDetector.mlpackage"))
    os.replace(os.path.join(OUT, "run", "weights", "best.pt"), os.path.join(OUT, "best.pt"))


if __name__ == "__main__":
    main()
