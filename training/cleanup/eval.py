"""Score cleanup checkpoints on the held-out test split, to pick which model ships.

    python training/cleanup/eval.py qwen-cleanup-grpo minicpm-cleanup-grpo
    python training/cleanup/eval.py Qwen/Qwen3.5-0.8B --rows 4        # smoke test, Mac

Reports the GRPO reward (see rewards.py), exact matches, and how often a rewrite adds a
word the speaker did not say. Speed on the Mac is measured separately with MLX.
"""

import argparse

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from common import DATA, render
from rewards import FILLERS, score, words

p = argparse.ArgumentParser()
p.add_argument("checkpoints", nargs="+")
p.add_argument("--rows", type=int, default=2000)
p.add_argument("--bs", type=int, default=64)
a = p.parse_args()

from datasets import load_dataset

test = load_dataset(DATA, split="test").select(range(a.rows))
dev = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
for ckpt in a.checkpoints:
    tok = AutoTokenizer.from_pretrained(ckpt, padding_side="left")
    model = AutoModelForCausalLM.from_pretrained(ckpt, dtype=torch.bfloat16 if dev == "cuda" else torch.float32).to(dev).eval()
    rewards, exact, invented = [], 0, 0
    for i in range(0, len(test), a.bs):
        rows = test[i:i + a.bs]
        batch = tok([render(tok, t) for t in rows["input"]], return_tensors="pt", padding=True, add_special_tokens=True).to(dev)
        with torch.no_grad():
            out = model.generate(**batch, max_new_tokens=256, do_sample=False)
        for o, target in zip(tok.batch_decode(out[:, batch.input_ids.shape[1]:], skip_special_tokens=True), rows["target"]):
            rewards.append(score(o, target))
            exact += o.strip() == target.strip()
            invented += bool(set(words(o)) - set(words(target)) - FILLERS)
    n = len(rewards)
    print(f"{ckpt}: reward {sum(rewards) / n:.3f}, exact {exact / n:.1%}, adds a word {invented / n:.1%} ({n} rows)", flush=True)
