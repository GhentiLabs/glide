#!/usr/bin/env bash
# Cleanup-model run on one RunPod GPU: for each model, SFT then GRPO, then score base, SFT and GRPO on the test
# split. Checkpoints go to the container disk (the Trainer keeps optimizer state); only finished models are copied
# to the network volume. Each step skips itself if its output exists, so rerunning resumes.
#   HF_TOKEN=... nohup bash cleanup/runpod_cleanup.sh qwen minicpm > /workspace/logs/cleanup.log 2>&1 &
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
WORK=/root/cleanup; OUT=/workspace/cleanup
export HF_HOME=/root/hf
mkdir -p "$WORK" "$OUT" /workspace/logs
step() { echo "=== $(date -u +%H:%M:%S) $*"; }

step env
if [ ! -x /root/trl/bin/python ]; then
  pip install -q --break-system-packages uv  # the image's system Python refuses plain pip installs
  uv venv -q --python 3.12 /root/trl
  uv pip install -q --python /root/trl/bin/python "trl[vllm]" datasets accelerate flash-linear-attention
fi
source /root/trl/bin/activate
python -c "import trl, vllm, torch; print('trl', trl.__version__, 'vllm', vllm.__version__, 'torch', torch.__version__)"
cd "$WORK"

step smoke
[ -f smoke.ok ] || {
  python "$here/sft.py" --model qwen --max_steps 3 --bs 4 --sft_rows 256 --out smoke-sft
  python "$here/grpo.py" --model qwen --init smoke-sft --out smoke-grpo --max_steps 1 --prompts 16 --G 4
  rm -rf smoke-sft smoke-grpo; touch smoke.ok
}

for m in "$@"; do
  step "sft $m"
  [ -f "$OUT/$m-cleanup-sft/config.json" ] || {
    python "$here/sft.py" --model "$m"
    mkdir -p "$OUT/$m-cleanup-sft"  # final weights only; checkpoint-* dirs hold optimizer state
    find "$m-cleanup-sft" -maxdepth 1 -type f -exec cp {} "$OUT/$m-cleanup-sft/" \;
  }
  step "grpo $m"
  [ -f "$OUT/$m-cleanup-grpo/config.json" ] || {
    python "$here/grpo.py" --model "$m" --init "$OUT/$m-cleanup-sft"
    mkdir -p "$OUT/$m-cleanup-grpo"  # final weights only; checkpoint-* dirs hold optimizer state
    find "$m-cleanup-grpo" -maxdepth 1 -type f -exec cp {} "$OUT/$m-cleanup-grpo/" \;
  }
  step "eval $m"
  base=$(python -c "import sys; sys.path.insert(0, '$here'); from common import MODELS; print(MODELS['$m'])")
  python "$here/eval.py" "$base" "$OUT/$m-cleanup-sft" "$OUT/$m-cleanup-grpo" | tee -a "$OUT/eval.txt"
done
step done
