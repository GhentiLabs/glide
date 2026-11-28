"""Transcribe a manifest with a Parakeet checkpoint, print its corpus WER, and optionally write
the clips it still gets wrong as the next GRPO set.

    python asr/mine_hard.py round-1.nemo /workspace/asr/test.jsonl                       # WER only
    python asr/mine_hard.py round-1.nemo /workspace/asr/train_teacher.jsonl --out hard-2.jsonl \\
        --teachers nemotron.jsonl qwen.jsonl

A miss is kept for GRPO when:
- its WER against the label is above 0 and at most MAX_WER. Past that the model rarely samples a
  right answer, so the group has no signal.
- the model's text doesn't match either teacher within 5% CER. If it does, the label is in doubt.
"""

import argparse
import json
import os
import random

from grpo_tdt import norm_words, wer

MAX_WER = 0.5


def main():
    import fluid_speech

    p = argparse.ArgumentParser()
    p.add_argument("model")
    p.add_argument("manifest")
    p.add_argument("--out", help="write misses here as a NeMo manifest")
    p.add_argument("--teachers", nargs="*", default=[], help="teacher_labels.py transcripts")
    p.add_argument("--sample", type=int, help="score a random subset of this many clips")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--batch_size", type=int, default=128)
    p.add_argument("--workers", type=int, default=16, help="audio decoding processes; one is the bottleneck on a GPU")
    a = p.parse_args()

    rows = [json.loads(l) for l in open(a.manifest)]
    if a.sample and a.sample < len(rows):
        rows = random.Random(a.seed).sample(rows, a.sample)
    model = fluid_speech.load(a.model)
    hyps = [h.text for h in model.transcribe([r["audio_filepath"] for r in rows], batch_size=a.batch_size, num_workers=a.workers, verbose=False)]

    ref_words = sum(len(norm_words(r["text"])) for r in rows)
    errors = sum(wer(h, r["text"]) * len(norm_words(r["text"])) for h, r in zip(hyps, rows))
    if a.out:
        from teacher_labels import AGREE_CER, cer

        teachers = [{t["audio_filepath"]: t["text"] for t in map(json.loads, open(f))} for f in a.teachers]
        kept = 0
        with open(a.out + ".tmp", "w") as f:  # renamed when complete, so rl_loop.sh never resumes from half a file
            for h, r in zip(hyps, rows):
                if not 0 < wer(h, r["text"]) <= MAX_WER:
                    continue
                if any(r["audio_filepath"] in t and cer(h, t[r["audio_filepath"]]) <= AGREE_CER for t in teachers):
                    continue
                f.write(json.dumps(r) + "\n")
                kept += 1
        os.replace(a.out + ".tmp", a.out)
        print(f"{kept} of {len(rows)} clips kept as misses in {a.out}")
    print(f"WER {errors / max(ref_words, 1):.4f}")


if __name__ == "__main__":
    main()
