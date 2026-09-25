#!/bin/sh
# Push train_damage.py to Kaggle as its own kernel with baked-in config (Kaggle kernels can't take env vars).
# Usage: ml/push_experiment.sh <name> KEY=VAL ...    e.g. ml/push_experiment.sh convnext384 ARCH=convnext_tiny IMG=384 EPOCHS=20
# Results: kaggle kernels output dongyeop0810/faultline-<name> -p ml/out/<name>
set -eu
name=$1; shift
here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d)
{
  echo "import os"
  for kv in "$@"; do echo "os.environ.setdefault('${kv%%=*}', '${kv#*=}')"; done
  cat "$here/train_damage.py"
} > "$dir/train.py"
sed -e "s#dongyeop0810/faultline-damage-classifier#dongyeop0810/faultline-$name#" \
    -e "s#\"FaultLine Damage Classifier\"#\"FaultLine $name\"#" \
    -e "s#\"train_damage.py\"#\"train.py\"#" "$here/kernel-metadata.json" > "$dir/kernel-metadata.json"
kaggle kernels push -p "$dir" --accelerator NvidiaTeslaT4
