"""Relabel the speech mix with two strong open teachers and keep the labels they agree on.
They come from different families, so their mistakes rarely match. Qwen3-ASR is the best open model on the
Open ASR Leaderboard's private (held-out) sets.

Each teacher runs as its own vLLM server (their environments differ, see README):

    python asr/teacher_labels.py transcribe /workspace/asr/train.jsonl nemotron.jsonl --model nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B
    python asr/teacher_labels.py transcribe /workspace/asr/train.jsonl qwen.jsonl --model Qwen/Qwen3-ASR-1.7B
    python asr/teacher_labels.py merge /workspace/asr/train.jsonl nemotron.jsonl qwen.jsonl /workspace/asr
    python asr/teacher_labels.py --selftest

merge writes train_teacher.jsonl and dev.jsonl (a random 2,000 of the clips both teachers agree on, held out
so the RL loop can pick rounds without touching the test set) into out_dir:
- Both teachers agree within 5% CER: Nemotron's text becomes the label.
- They disagree but one agrees with the source label: that teacher's text (counted as hard).
- No two agree: the clip is dropped, since nothing can be trusted as its reference.
GRPO sets come later from mine_hard.py, which picks what the trained model still gets wrong.
"""

import argparse
import asyncio
import base64
import io
import json
import random
import re
from pathlib import Path

AGREE_CER = 0.05
# Verbatim, so fillers stay for the cleanup model to remove (prompt from the Nemotron model card).
NEMOTRON_PROMPT = ("Audio transcription. Language: as spoken. Wording: verbatim, including fillers and repetitions. "
                   "Formatting: punctuation and capitalization. Output: transcript only.")
FILLERS = {"um", "uh", "erm", "er", "ah", "hmm", "mm", "mhm"}


def norm(t: str) -> str:
    return " ".join(w for w in re.findall(r"[a-z0-9']+", t.lower()) if w not in FILLERS)


def cer(a: str, b: str) -> float:
    from rapidfuzz.distance import Levenshtein
    a, b = norm(a), norm(b)
    return Levenshtein.distance(a, b) / max(len(b), 1)


def decide(nemotron: str, qwen: str, source: str):
    """Returns (label, hard) or None to drop."""
    if cer(nemotron, qwen) <= AGREE_CER:
        return nemotron, False
    if cer(nemotron, source) <= AGREE_CER:
        return nemotron, True
    if cer(qwen, source) <= AGREE_CER:
        return qwen, True
    return None


def parse(content: str) -> str:
    # Qwen3-ASR answers "language English<asr_text>...", Nemotron answers with the text alone.
    return content.split("<asr_text>")[-1].strip()


def wav_data_url(path: str) -> str:
    import soundfile as sf
    x, sr = sf.read(path, dtype="int16")
    buf = io.BytesIO()
    sf.write(buf, x, sr, format="WAV")
    return "data:audio/wav;base64," + base64.b64encode(buf.getvalue()).decode()


async def transcribe(manifest: Path, out: Path, model: str, url: str, concurrency: int):
    from openai import AsyncOpenAI

    client = AsyncOpenAI(base_url=url, api_key="EMPTY", timeout=600)
    done = {json.loads(l)["audio_filepath"] for l in out.open()} if out.exists() else set()
    rows = [r for r in map(json.loads, manifest.open()) if r["audio_filepath"] not in done]
    content = [{"type": "text", "text": NEMOTRON_PROMPT}] if "Nemotron" in model else []
    extra = {"chat_template_kwargs": {"enable_thinking": False}} if "Nemotron" in model else {}
    todo, n = iter(rows), 0

    async def worker(f):
        for r in todo:  # workers share one iterator, so each clip is sent once
            await one(r, f)

    async def one(r, f):
        nonlocal n
        try:
            audio = {"type": "audio_url", "audio_url": {"url": wav_data_url(r["audio_filepath"])}}
            resp = await client.chat.completions.create(
                model=model, temperature=0, max_tokens=512, extra_body=extra,
                messages=[{"role": "user", "content": content + [audio]}])
        except Exception as e:  # a bad file or failed request must not stop the run; retried on resume, and an
            # unreadable clip never gets a label, so merge leaves it out of training
            print("skipped", r["audio_filepath"], type(e).__name__, flush=True)
            return
        # an empty reply becomes an empty label, which merge drops (teachers can't agree on it)
        f.write(json.dumps({"audio_filepath": r["audio_filepath"], "text": parse(resp.choices[0].message.content or "")}) + "\n")
        n += 1
        if n % 10_000 == 0:
            f.flush()
            print(f"{n + len(done)} / {len(rows) + len(done)}", flush=True)

    with out.open("a") as f:
        await asyncio.gather(*(worker(f) for _ in range(concurrency)))
    print(f"{out}: {n} new, {n + len(done)} total")


def merge(manifest: Path, nemotron: Path, qwen: Path, out_dir: Path, n_dev: int = 2000):
    load = lambda p: {r["audio_filepath"]: r["text"] for r in map(json.loads, p.open())}
    nt, qt = load(nemotron), load(qwen)
    counts = {"agree": 0, "hard": 0, "dropped": 0, "missing": 0}
    kept, agreed = [], []
    for r in map(json.loads, manifest.open()):
        k = r["audio_filepath"]
        if k not in nt or k not in qt:
            counts["missing"] += 1
            continue
        d = decide(nt[k], qt[k], r["text"])
        if d is None:
            counts["dropped"] += 1
            continue
        (agreed if not d[1] else []).append(len(kept))
        kept.append({**r, "text": d[0], "source_text": r["text"]})
        counts["hard" if d[1] else "agree"] += 1
    dev = set(random.Random(0).sample(agreed, min(n_dev, len(agreed))))
    with (out_dir / "train_teacher.jsonl").open("w") as ft, (out_dir / "dev.jsonl").open("w") as fd:
        for i, r in enumerate(kept):
            (fd if i in dev else ft).write(json.dumps(r) + "\n")
    print(counts, f"dev {len(dev)}")


def selftest():
    assert parse("language English<asr_text>Hello there.") == "Hello there."
    assert cer("Um, I went to the store.", "I went to the store") == 0
    assert decide("I went to the store.", "I went to the store", "i went to the shop") == ("I went to the store.", False)
    assert decide("I sent it Tuesday.", "I spent it today.", "I sent it Tuesday") == ("I sent it Tuesday.", True)
    assert decide("Apples are red.", "Pears are green.", "Plums are blue.") is None
    print("teacher_labels selftest ok")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--selftest", action="store_true")
    sub = p.add_subparsers(dest="cmd")
    t = sub.add_parser("transcribe")
    t.add_argument("manifest", type=Path)
    t.add_argument("out", type=Path)
    t.add_argument("--model", required=True)
    t.add_argument("--url", default="http://127.0.0.1:8000/v1")
    t.add_argument("--concurrency", type=int, default=256)
    m = sub.add_parser("merge")
    m.add_argument("manifest", type=Path)
    m.add_argument("nemotron", type=Path)
    m.add_argument("qwen", type=Path)
    m.add_argument("out_dir", type=Path)
    a = p.parse_args()
    if a.selftest:
        selftest()
    elif a.cmd == "transcribe":
        asyncio.run(transcribe(a.manifest, a.out, a.model, a.url, a.concurrency))
    elif a.cmd == "merge":
        merge(a.manifest, a.nemotron, a.qwen, a.out_dir)
