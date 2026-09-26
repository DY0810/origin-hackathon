#!/bin/sh
# Downloads the Whisper tiny.en Core ML model (+ tokenizer) that the app bundles for on-device dictation.
# ~77 MB; gitignored like the other model artifacts. Run once before building: ios/scripts/fetch_whisper.sh
# Without it the app still builds; the note field just has no mic button.
set -eu
dest="$(cd "$(dirname "$0")/.." && pwd)/Whisper/openai_whisper-tiny.en"
hf=https://huggingface.co
for f in config.json generation_config.json \
  AudioEncoder.mlmodelc/analytics/coremldata.bin AudioEncoder.mlmodelc/coremldata.bin AudioEncoder.mlmodelc/metadata.json \
  AudioEncoder.mlmodelc/model.mil AudioEncoder.mlmodelc/model.mlmodel AudioEncoder.mlmodelc/weights/weight.bin \
  MelSpectrogram.mlmodelc/analytics/coremldata.bin MelSpectrogram.mlmodelc/coremldata.bin MelSpectrogram.mlmodelc/metadata.json \
  MelSpectrogram.mlmodelc/model.mil MelSpectrogram.mlmodelc/weights/weight.bin \
  TextDecoder.mlmodelc/analytics/coremldata.bin TextDecoder.mlmodelc/coremldata.bin TextDecoder.mlmodelc/metadata.json \
  TextDecoder.mlmodelc/model.mil TextDecoder.mlmodelc/model.mlmodel TextDecoder.mlmodelc/weights/weight.bin; do
  mkdir -p "$dest/$(dirname "$f")"
  curl -fsSL -o "$dest/$f" "$hf/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-tiny.en/$f"
done
for f in tokenizer.json tokenizer_config.json; do  # WhisperKit looks for the tokenizer inside the model folder
  curl -fsSL -o "$dest/$f" "$hf/openai/whisper-tiny.en/resolve/main/$f"
done
du -sh "$dest"
