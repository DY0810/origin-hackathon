# FaultLine damage model

On-device prefilter + damage-type suggestion for the iOS app (CLAUDE.md §6.2, §7.3). **The server-side Claude vision call stays the authority for acceptance and severity.** This model gives instant feedback, powers gallery scan, and pre-fills the DamageTypeChip.

## v1: multi-label EfficientNet-B0 → Core ML

- **Classes:** `crack, spalling, efflorescence, exposed_rebar, corrosion, pothole`. "No damage" means all probabilities below threshold.
- **Training:** Kaggle kernel [`dongyeop0810/faultline-damage-classifier`](https://www.kaggle.com/code/dongyeop0810/faultline-damage-classifier), T4 GPU, 12 epochs, 320 px, ImageNet-pretrained.
- **Outputs** (`kaggle kernels output dongyeop0810/faultline-damage-classifier -p out`):
  - `FaultLineDamage.mlpackage`: input `image` (320×320 RGB), output `probabilities` [1×6], sigmoid applied.
  - `labels.json`: class order + per-class thresholds tuned on val F1.
  - `metrics.json`: test AP / F1 per class, any-damage AUC, data counts, training history.
  - `model.pt`: PyTorch weights.

### v1 results (Kaggle run 2026-09-24, held-out test set)

| Class | AP | F1 @ tuned threshold | Test n | Threshold |
|---|---|---|---|---|
| crack | 0.987 | 0.950 | 400 | 0.75 |
| spalling | 0.919 | 0.824 | 150 | 0.80 |
| efflorescence | 0.910 | 0.811 | 149 | 0.75 |
| exposed_rebar | 0.977 | 0.919 | 150 | 0.75 |
| corrosion | 0.845 | 0.789 | 150 | 0.80 |
| pothole | 1.000 | 0.971 | 33 | 0.10 ⚠ |

- **mAP 0.940. Damage vs no-damage AUC 0.995.** Train set: 10,556 images. Best checkpoint at epoch 10 (val mAP 0.932), about 2.3 min/epoch on a T4.
- **Caveats:**
  - The test sets come from the same sources as training, so real phone photos of different assets will score lower. Validate on our own photos before quoting numbers in the pitch.
  - The pothole class is tiny (33 test images) and its tuned threshold of 0.10 isn't trustworthy. Use 0.5 in the app until RDD2022 is added.

### v2 experiments (2026-09-25): targeting spalling / efflorescence / corrosion

Changes: masked loss (sources only train the labels they annotate), TrivialAugment + random erasing, flip TTA, 16 epochs, 384 px.

| Run | Params | spalling F1 | efflorescence F1 | corrosion F1 | corrosion AP | mAP |
|---|---|---|---|---|---|---|
| v1 b0 @320 | 5.3M | 0.824 | 0.811 | 0.789 | 0.845 | 0.940 |
| **b0 @384** | 5.3M | 0.824 | 0.824 | **0.821** | 0.889 | 0.949 |
| convnext_tiny @384 | 28M | 0.823 | **0.847** | 0.806 | **0.895** | **0.954** |

- **Pick for on-device: b0 @384.** ConvNeXt is marginally better on AP but 5× larger. It's not worth it on a phone.
- Spalling is flat at ~0.82. CODEBRIM's spalling and exposed-rebar labels overlap heavily, so more data beats more model here.
- v3 adds spalling-like holes (wall dataset) and MBDD corrosion.

### Datasets (Kaggle)

| Dataset | What | Used as |
|---|---|---|
| [CODEBRIM balanced](https://www.kaggle.com/datasets/sristi29raj/codebrim-balanced-dataset) | Field photos of concrete bridge defects, multi-label, with its own train/val/test split | crack, spalling, efflorescence, exposed_rebar, corrosion + background |
| [Pothole Detection](https://www.kaggle.com/datasets/atulyakumar98/pothole-detection-dataset) | Road photos, `potholes` / `normal` | pothole + no damage (80/10/10 split) |
| [Surface Crack Detection](https://www.kaggle.com/datasets/arunrk7/surface-crack-detection) | 40k close-up concrete patches, `Positive` / `Negative` | crack + no damage (capped at 2,500 each) |

**Dataset licenses aren't stated on Kaggle.** CODEBRIM's original license is research-only. That's fine for a hackathon demo; re-check before any commercial use.

### Rejected
- **RDD2022** (road damage, 10.6 GB, bounding boxes): good street-level data but too big for v1. It's the first thing to add for v2 (crop boxes → classes).
- **xBD**: it has 4-level damage severity, but it's satellite imagery and doesn't match phone photos. Candidate for disaster mode later.
- **Ground-level AeDES dataset** (`muhammadzamanzahid/…`, 20 GB, Italian post-earthquake element labels): too large for v1. Worth a look for building damage.

## Severity (not learned in v1)

No public street-level dataset has severity labels. v1 severity = **Claude vision on the server** (authoritative), plus this on-device heuristic for the instant *preliminary* badge (label it "Preliminary" per design-system/MASTER.md §7.2):

| Signal (probabilities over threshold) | Preliminary severity |
|---|---|
| efflorescence only | 1 Cosmetic |
| corrosion or hairline crack only | 2 Monitor |
| crack (p ≥ 0.8), spalling, or pothole | 3 Repair soon |
| exposed_rebar, or spalling + corrosion | 4 Urgent |
| 5 Hazard | never on-device; only from server / human review |

**v2 plan:** distill severity. Every server-verified report gives an (image, Claude severity, human-reviewed severity) triple. Fine-tune a severity head on those once there are a few thousand. This is our data moat and belongs in the "What's next" pitch slide.

## Local use

```bash
cd ml && uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python torch torchvision scikit-learn pillow coremltools
INPUT=/path/to/datasets EPOCHS=1 CAP=60 IMG=224 .venv/bin/python train_damage.py   # smoke test
kaggle kernels push -p . --accelerator NvidiaTeslaT4                                  # full run on Kaggle
```

Core ML export uses a single normalization std (0.226) for all channels. Verified against PyTorch: max probability diff 0.013.
