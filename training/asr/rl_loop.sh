#!/usr/bin/env bash
# RL-only training of the speech model, starting from Fluid Speech Pro (no supervised fine-tune: on
# imperfect teacher labels it makes the model copy their errors, while RL scored against them mostly
# does not, see arXiv 2610.32572). Each round mines what the newest model still gets wrong, runs GRPO
# on it, and keeps the result only if dev WER drops (dev is held out by teacher_labels.py merge). Stops at
# the first round that doesn't help, then reports test WER for the start and the winner.
#   bash asr/rl_loop.sh FluidVoice-Labs/fluid-speech-pro /workspace/asr 5
set -euo pipefail
cd "$(dirname "$0")"
model=${1:-FluidVoice-Labs/fluid-speech-pro}; dir=${2:-/workspace/asr}; rounds=${3:-5}
wer_on() { python mine_hard.py "$1" "$dir/$2.jsonl" | tail -1 | awk '{print $2}'; }

start=$model
best=$(wer_on "$model" dev)
echo "start: $model, dev WER $best"
for r in $(seq 1 "$rounds"); do
  # ~7% of clips are misses at the start, so 120k gives ~9k: about 280 GRPO steps of 32. A new sample each round.
  # A rerun resumes: each round's misses and model are reused if present (delete hard-* and round-* to start over)
  [ -f "$dir/hard-$r.jsonl" ] || python mine_hard.py "$model" "$dir/train_teacher.jsonl" --sample 120000 --seed "$r" \
    --out "$dir/hard-$r.jsonl" --teachers "$dir/nemotron.jsonl" "$dir/qwen.jsonl"
  [ -f "$dir/round-$r.nemo" ] || python grpo_tdt.py --model "$model" --data "$dir/hard-$r.jsonl" --out "$dir/round-$r.nemo"
  w=$(wer_on "$dir/round-$r.nemo" dev)
  echo "round $r: dev WER $w (best $best)"
  python -c "import sys; sys.exit(0 if $w < $best else 1)" || break
  model="$dir/round-$r.nemo"; best=$w
done
echo "best: $model, dev WER $best"
echo "test WER: start $(wer_on "$start" test), best $(wer_on "$model" test)"
