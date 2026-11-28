# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["huggingface_hub>=0.30", "pyarrow", "num2words"]
# ///
"""Build transcript-cleanup pairs for the Glide cleanup model.

Clean side: written English from public-domain and CC sources. Spoken side: made from it
by rules (spoken numbers, fillers, repeats, self-corrections, lost punctuation), so the
target is exact. disfl_qa adds human-written disfluent questions, and oasst2 requests people
typed to an assistant, so the model learns to clean a request up and never carry it out. Teacher-model pairs on
real recognizer output come later, on rented GPUs.

Only public data goes in. The user's own dictations never do.

    uv run training/build_cleanup.py --repo Stelath/glide-cleanup-en
    uv run training/build_cleanup.py --selftest
"""

import argparse
import gzip
import json
import random
import re
from pathlib import Path

from num2words import num2words

SOURCES = [  # (name, glob under datasets/, field, license, max documents)
    ("stackexchange", "common-pile/stackexchange/*.stackexchange.com/documents/00000_se.jsonl.gz", "text", "cc-by-sa-4.0", 40_000),
    ("youtube_commons", "common-pile/youtube/0000[0-3]_youtube_commons.jsonl.gz", "text", "cc-by-4.0", 20_000),
    ("peps", "common-pile/python_enhancement_proposals/v0/documents/*.jsonl.gz", "text", "public-domain", 1_000),
]
FILLERS = ["um", "uh", "like", "you know", "I mean", "so", "kind of", "basically"]
CORRECTIONS = ["no, sorry,", "I mean", "actually,", "no wait,", "sorry,", "or rather"]
CODEY = re.compile(r"[{}<>=;$\\|`#@]|https?://|\w+\(\)|\w+\.\w+\(")


def sentences(text: str):
    for para in text.split("\n"):
        for s in re.split(r"(?<=[.!?])\s+", para.strip()):
            w = s.split()
            if 4 <= len(w) <= 40 and s[0].isupper() and s[-1] in ".!?" and not CODEY.search(s) and s.isascii():
                yield s


def say_number(tok: str) -> str:
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(%?)([.,!?]?)", tok)
    if not m:
        return tok
    n, pct, p = m.groups()
    if "." in n:
        a, b = n.split(".")
        words = f"{num2words(int(a))} point {' '.join(num2words(int(d)) for d in b)}"
    else:
        words = num2words(int(n), to="year") if len(n) == 4 and 1900 <= int(n) <= 2099 else num2words(int(n))
    return words.replace("-", " ").replace(",", "") + (" percent" if pct else "") + p


def spoken(clean: str, rng: random.Random, pool: list[str]) -> str:
    """Written text -> what a recognizer might output for someone saying it."""
    words = [say_number(t) for t in clean.replace("&", "and").split()]
    # self-correction: say a wrong word or number first, then the right one
    if rng.random() < 0.3:
        idx = [i for i, w in enumerate(words) if i and (w[:1].isupper() or w[:1].isdigit()) and w.isalpha()]
        if idx and pool:
            i = rng.choice(idx)
            wrong = rng.choice(pool)
            if wrong.lower() != words[i].lower():
                words[i:i] = [wrong, rng.choice(CORRECTIONS)]
    out = []
    for w in words:
        if rng.random() < 0.05:
            out.append(rng.choice(FILLERS) + ",")
        if rng.random() < 0.03 and len(w) <= 4:
            out.append(w)  # stutter repeat
        out.append(w)
    text = " ".join(out)
    if rng.random() < 0.5:
        text = re.sub(r",(?= )", "", text) if rng.random() < 0.5 else text
        text = re.sub(r"[.!?]$", "", text)
    if rng.random() < 0.3:
        text = text[0].lower() + text[1:]
    return text


def request_text(r: dict) -> str | None:
    """An English opening prompt from oasst2 that is plain prose of at most three sentences, else None."""
    if r["lang"] != "en" or r["parent_id"] or r["deleted"] or (r["detoxify"] or {}).get("toxicity", 0) > 0.5:
        return None
    t = r["text"].strip()
    n = len(t.split())
    ok = "\n" not in t and 4 <= n <= 60 and len(re.split(r"(?<=[.!?])\s+", t)) <= 3
    return " ".join(t.split()) if ok and t[0].isupper() and t[-1] in ".!?" and t.isascii() and not CODEY.search(t) else None


def read_docs(fs, pattern: str, field: str, limit: int):
    n = 0
    for path in sorted(fs.glob(f"datasets/{pattern}")):
        with gzip.open(fs.open(path)) as f:
            for j, line in enumerate(f):
                if j >= 300:  # spread across files (Stack Exchange: one file per site)
                    break
                yield json.loads(line)[field]
                n += 1
                if n >= limit:
                    return


def build(out: Path, repo: str | None, seed: int):
    import pyarrow as pa
    import pyarrow.parquet as pq
    from huggingface_hub import HfApi, HfFileSystem

    fs, rng = HfFileSystem(), random.Random(seed)
    rows = []
    for name, pattern, field, lic, limit in SOURCES:
        sents = [s for d in read_docs(fs, pattern, field, limit) for s in sentences(d)]
        pool = sorted({w.strip(".,!?") for s in sents for w in s.split()[1:] if w[:1].isupper() and w.strip(".,!?").isalpha()})
        rng.shuffle(sents)
        i = 0
        while i < len(sents):
            k = rng.choice([1, 1, 2, 3])  # dictations are often a few sentences
            clean = " ".join(sents[i:i + k])
            i += k
            passthrough = rng.random() < 0.1
            rows.append({"input": clean if passthrough else spoken(clean, rng, pool), "target": clean,
                         "source": name, "license": lic, "kind": "passthrough" if passthrough else "rules"})
        print(f"{name}: {len(sents)} sentences", flush=True)
    f = "datasets/OpenAssistant/oasst2/2023-11-05_oasst2_prompts.messages.jsonl.gz"
    reqs = [c for c in map(request_text, map(json.loads, gzip.open(fs.open(f)))) if c]
    pool = sorted({w.strip(".,!?") for s in reqs for w in s.split()[1:] if w[:1].isupper() and w.strip(".,!?").isalpha()})
    for clean in reqs:
        for _ in range(2):  # two noisy versions each, since requests are rare in the written sources
            rows.append({"input": spoken(clean, rng, pool), "target": clean,
                         "source": "oasst2", "license": "apache-2.0", "kind": "request"})
    print(f"oasst2: {len(reqs)} requests", flush=True)
    for split in ("train", "validation", "test"):
        f = f"datasets/google-research-datasets/disfl_qa/data/{split}-00000-of-00001.parquet"
        for r in pq.read_table(fs.open(f)).to_pylist():
            if r["disfluent question"] and r["original question"]:
                rows.append({"input": r["disfluent question"], "target": r["original question"],
                             "source": "disfl_qa", "license": "cc-by-4.0", "kind": "human"})
    rng.shuffle(rows)
    n_test = 2000
    out.mkdir(parents=True, exist_ok=True)
    files = {"data/test.parquet": rows[:n_test], "data/train.parquet": rows[n_test:]}
    for rel, part in files.items():
        (out / rel).parent.mkdir(parents=True, exist_ok=True)
        pq.write_table(pa.Table.from_pylist(part), out / rel)
        print(rel, len(part), "pairs")
    if repo:
        api = HfApi()
        api.create_repo(repo, repo_type="dataset", private=True, exist_ok=True)
        if not api.repo_info(repo, repo_type="dataset").private:
            raise SystemExit(f"{repo} is public; refusing to upload")
        api.upload_folder(folder_path=str(out / "data"), path_in_repo="data", repo_id=repo, repo_type="dataset")


def selftest():
    rng = random.Random(0)
    assert say_number("3.5") == "three point five"
    assert say_number("2026,") == "twenty twenty six,"
    assert say_number("40%") == "forty percent"
    assert say_number("v2") == "v2"
    assert list(sentences("Short. This one has enough words in it. x = foo(); is code here.")) == ["This one has enough words in it."]
    for _ in range(200):
        s = spoken("Send the file to Sarah by 5 today.", rng, ["Tom"])
        assert "Sarah" in s, s  # the right word always survives a self-correction
        assert "5" not in s, s
    base = {"lang": "en", "parent_id": None, "deleted": False, "detoxify": None}
    assert request_text({**base, "text": "Write an email to my boss asking for Friday off. Keep it short."}) == \
        "Write an email to my boss asking for Friday off. Keep it short."
    assert request_text({**base, "text": "Fix this:\n```x = 1```"}) is None
    assert request_text({**base, "lang": "es", "text": "Escribe un correo a mi jefe por favor."}) is None
    print("selftest ok")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, default=Path.home() / "glide-data" / "cleanup")
    p.add_argument("--repo", help="private HF dataset repo, e.g. Stelath/glide-cleanup-en")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    selftest() if a.selftest else build(a.out.expanduser(), a.repo, a.seed)
