#!/bin/zsh
# Energy per cleanup on the Neural Engine vs MLX on the GPU, and for one nightly LoRA run. Asks for your password once, for powermetrics.
set -e
cd "${0:A:h}"
sudo -v
out=~/glide-data/coreml/power.txt
: > $out
~/glide-data/coreml-venv/bin/python power_bench.py idle 40 | tee -a $out
sudo -v
~/glide-data/coreml-venv/bin/python power_bench.py ane 45 2>/dev/null | tee -a $out
sudo -v
~/glide-data/eval/mlx/bin/python power_bench.py mlx 45 2>/dev/null | tee -a $out
sudo -v
~/glide-data/eval/mlx/bin/python power_bench.py train 0 2>/dev/null | tee -a $out
~/glide-data/coreml-venv/bin/python power_bench.py idle 40 | tee -a $out
echo "saved to $out"
