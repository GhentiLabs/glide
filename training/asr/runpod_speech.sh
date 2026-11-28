#!/usr/bin/env bash
# The whole RL-only speech run on one RunPod GPU (RTX PRO 6000, 96 GB). Every step skips itself if its output
# exists, so after a restart rerunning this resumes. Outputs live on the network volume (/workspace); the
# environment, models and unpacked audio live on the container disk and are rebuilt after a restart.
#   HF_TOKEN=... nohup bash asr/runpod_speech.sh > /workspace/logs/run.log 2>&1 &
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
W=/workspace; OUT=$W/asr; AUDIO=/root/asr
export HF_HOME=/root/hf PATH=/usr/local/cuda/bin:$PATH
mkdir -p "$OUT" "$W/logs"
step() { echo "=== $(date -u +%H:%M:%S) $*"; }

step env
if [ ! -x /root/nemo-speech/.venv/bin/python ]; then
  pip install -q --break-system-packages uv  # the image's system Python refuses plain pip installs
  git clone -q https://github.com/NVIDIA-NeMo/Speech.git /root/nemo-speech
  cd /root/nemo-speech
  uv venv -q --python 3.13 .venv
  UV_PROJECT_ENVIRONMENT=$PWD/.venv uv sync -q --extra asr --extra vllm --locked --no-install-project
  uv pip install -q --python .venv/bin/python --no-deps -e .
  uv pip install -q --python .venv/bin/python --no-deps av==19.0.2 opencv-python-headless==5.0.0.93
  uv pip install -q --python .venv/bin/python rapidfuzz openai
  cd "$here"
fi
source /root/nemo-speech/.venv/bin/activate

step data
# A third of the training shards from each source (~1,000 h) and all test shards
python - <<'EOF'
import re
from huggingface_hub import HfApi, snapshot_download
files = HfApi().list_repo_files("Stelath/glide-asr-en", repo_type="dataset")
pick = [f for f in files if f.startswith("data/test/")]
for f in files:
    m = re.match(r"data/train/.+-(\d+)-\d+\.parquet$", f)
    if m and int(m.group(1)) % 3 == 0:
        pick.append(f)
snapshot_download("Stelath/glide-asr-en", repo_type="dataset", local_dir="/workspace/glide-asr-en", allow_patterns=pick)
print(len(pick), "shards")
EOF
[ -f "$AUDIO/train.jsonl" ] || python "$here/prepare_manifests.py" "$W/glide-asr-en" "$AUDIO"
cp -n "$AUDIO/train.jsonl" "$AUDIO/test.jsonl" "$OUT/"

serve_and_label() {  # name, model, then vllm serve arguments
  local name=$1 model=$2; shift 2
  [ -f "$OUT/$name.done" ] && return
  step "teacher $name"
  vllm serve "$model" --port 8000 "$@" > "$W/logs/vllm-$name.log" 2>&1 &
  local pid=$!
  until curl -sf localhost:8000/health > /dev/null; do
    kill -0 $pid 2> /dev/null || { echo "vllm $name died, see logs/vllm-$name.log"; exit 1; }
    sleep 10
  done
  python "$here/teacher_labels.py" transcribe "$OUT/train.jsonl" "$OUT/$name.jsonl" --model "$model"
  kill $pid; wait $pid || true
  touch "$OUT/$name.done"
}

# Serving flags from the Nemotron FP8 model card's RTX PRO 6000 profile, without the timestamp middleware
export VLLM_PLUGINS=nemo_speechlm VLLM_DISABLED_KERNELS=FlashInferFP8ScaledMMLinearKernel
serve_and_label nemotron nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-FP8 \
  --trust-remote-code --dtype bfloat16 --kv-cache-dtype auto --gpu-memory-utilization 0.85 \
  --max-model-len 65536 --max-num-batched-tokens 4096 --max-num-seqs 64 \
  --enable-chunked-prefill --no-enable-prefix-caching \
  --use-replayssm --mamba-backend flashinfer --mamba-cache-mode none \
  --mm-processor-cache-gb 0 --no-async-scheduling \
  --limit-mm-per-prompt '{"audio":{"count":1,"length":57600000}}' \
  --speculative-config '{"method":"mtp","num_speculative_tokens":8}' \
  --reasoning-parser nemotron_v3 --trust-request-mm-kwargs
unset VLLM_PLUGINS VLLM_DISABLED_KERNELS
serve_and_label qwen Qwen/Qwen3-ASR-1.7B --gpu-memory-utilization 0.85 --max-num-seqs 256

step merge
[ -f "$OUT/train_teacher.jsonl" ] || python "$here/teacher_labels.py" merge "$OUT/train.jsonl" "$OUT/nemotron.jsonl" "$OUT/qwen.jsonl" "$OUT"

step rl
bash "$here/rl_loop.sh" FluidVoice-Labs/fluid-speech-pro "$OUT" 5
step done
