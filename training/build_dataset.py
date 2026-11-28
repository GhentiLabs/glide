# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["huggingface_hub>=0.30", "av>=14", "numpy", "pyarrow"]
# ///
"""Build the Glide English speech mix: read public HF parquet files one at a time,
re-encode audio to 16 kHz mono Opus, write Parquet shards, push them to a private
HF dataset repo, and keep a local copy while disk allows.

Only public or synthetic data goes in. The user's own dictations never do.

    uv run training/build_dataset.py --repo Stelath/glide-asr-en
    uv run training/build_dataset.py --selftest
"""

import argparse
import io
import json
import multiprocessing as mp
import re
import shutil
from pathlib import Path

import av
import numpy as np

from sources import SOURCES

SR = 16_000
OPUS_BITRATE = 32_000  # ~15 MB per hour: 3,000 h stays well under the 100 GB free private quota
SHARD_SECONDS = 3 * 3600
MIN_S, MAX_S = 0.5, 40.0
MIN_FREE_GB = 20  # below this, uploaded shards are deleted locally


def decode(raw: bytes) -> np.ndarray:
    """Any container/codec -> float32 mono 16 kHz."""
    with av.open(io.BytesIO(raw)) as f:
        rs = av.AudioResampler(format="flt", layout="mono", rate=SR)
        chunks = [p.to_ndarray().reshape(-1) for fr in f.decode(audio=0) for p in rs.resample(fr)]
        chunks += [p.to_ndarray().reshape(-1) for p in rs.resample(None)]
    return np.concatenate(chunks) if chunks else np.zeros(0, np.float32)


def encode_opus(x: np.ndarray) -> bytes:
    buf = io.BytesIO()
    with av.open(buf, "w", format="ogg") as f:
        s = f.add_stream("libopus", rate=SR, layout="mono")
        s.bit_rate = OPUS_BITRATE
        fr = av.AudioFrame.from_ndarray(x.reshape(1, -1).astype(np.float32), format="flt", layout="mono")
        fr.sample_rate = SR
        for p in s.encode(fr):
            f.mux(p)
        for p in s.encode(None):
            f.mux(p)
    return buf.getvalue()


def clean_text(t: str) -> str:
    return re.sub(r"\s+", " ", t or "").strip()


def process(job):
    """Worker: (raw audio bytes, text, row id) -> encoded row, or None if filtered."""
    raw, text, rid = job
    text = clean_text(text)
    if not text or not raw:
        return None
    try:
        x = decode(raw)
    except Exception:
        return None
    dur = len(x) / SR
    # chars per second outside 2..30 means a misaligned or empty segment
    if not (MIN_S <= dur <= MAX_S) or not (2 <= len(text) / dur <= 30):
        return None
    return {"id": rid, "audio": encode_opus(x), "text": text, "duration": round(dur, 3)}


def source_files(fs, src) -> list[str]:
    files = sorted(p for p in fs.glob(f"datasets/{src['repo']}/{src['files']}") if p.endswith(".parquet"))
    return files[:: src.get("stride", 1)]


def jobs(fs, path, src):
    import pyarrow.parquet as pq

    keep = src.get("keep")
    cols = sorted({"audio", src["text"], *src.get("columns", [])})
    pf = pq.ParquetFile(fs.open(path, block_size=64 << 20))
    stem = "_".join(Path(path).with_suffix("").parts[-3:])  # file names repeat across folders (YODAS en000/, en001/...)
    for g in range(pf.num_row_groups):
        for i, r in enumerate(pf.read_row_group(g, columns=cols).to_pylist()):
            if keep and not keep(r):
                continue
            yield (r["audio"] or {}).get("bytes"), r[src["text"]], f"{src['name']}-{stem}-{g}-{i}"


def write_shard(path: Path, batch, src):
    import pyarrow as pa
    import pyarrow.parquet as pq

    n = len(batch)
    table = pa.table({
        "id": [b["id"] for b in batch],
        "audio": pa.array([{"bytes": b["audio"], "path": f"{b['id']}.opus"} for b in batch],
                          pa.struct([("bytes", pa.binary()), ("path", pa.string())])),
        "text": [b["text"] for b in batch],
        "duration": pa.array([b["duration"] for b in batch], pa.float32()),
        "source": [src["name"]] * n, "license": [src["license"]] * n, "style": [src["style"]] * n,
    })
    # datasets reads this to show `audio` as an Audio column on the Hub
    feats = {k: {"dtype": t, "_type": "Value"} for k, t in
             [("id", "string"), ("text", "string"), ("duration", "float32"), ("source", "string"),
              ("license", "string"), ("style", "string")]}
    feats["audio"] = {"sampling_rate": SR, "_type": "Audio"}
    table = table.replace_schema_metadata({"huggingface": json.dumps({"info": {"features": feats}})})
    pq.write_table(table, path, row_group_size=100)


def build(out: Path, repo: str | None, only: set[str] | None, workers: int):
    from huggingface_hub import HfApi, HfFileSystem

    api, fs = (HfApi() if repo else None), HfFileSystem()
    if api:
        api.create_repo(repo, repo_type="dataset", private=True, exist_ok=True)
        if not api.repo_info(repo, repo_type="dataset").private:
            raise SystemExit(f"{repo} is public; refusing to upload")
    out.mkdir(parents=True, exist_ok=True)
    state_path = out / "state.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    with mp.Pool(workers) as pool:
        for src in SOURCES:
            if only and src["name"] not in only:
                continue
            st = state.setdefault(src["name"], {"done": [], "seconds": 0.0})
            for fi, path in enumerate(source_files(fs, src)):
                if st["seconds"] >= src["hours"] * 3600:
                    break
                if path in st["done"]:
                    continue
                batch, secs, part, file_secs = [], 0.0, 0, 0.0
                for res in pool.imap(process, jobs(fs, path, src), chunksize=8):
                    if res is None:
                        continue
                    batch.append(res)
                    secs += res["duration"]
                    if secs >= SHARD_SECONDS:
                        flush(out, api, repo, src, fi, part, batch)
                        file_secs += secs
                        batch, secs, part = [], 0.0, part + 1
                if batch:
                    flush(out, api, repo, src, fi, part, batch)
                    file_secs += secs
                # a file counts only once all its shards are up, so a crash redoes it under the same names
                st["done"].append(path)
                st["seconds"] += file_secs
                state_path.write_text(json.dumps(state, indent=1))
                print(f"{src['name']}: {st['seconds'] / 3600:.1f} / {src['hours']} h  ({Path(path).name})", flush=True)


def flush(out, api, repo, src, fi, part, batch):
    rel = f"data/{src['split']}/{src['name']}-{fi:05d}-{part:02d}.parquet"
    path = out / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    write_shard(path, batch, src)
    if api:
        api.upload_file(path_or_fileobj=str(path), path_in_repo=rel, repo_id=repo, repo_type="dataset")
        if shutil.disk_usage(out).free < MIN_FREE_GB * 1e9:
            path.unlink()


def selftest():
    t = np.linspace(0, 2, 2 * SR, endpoint=False, dtype=np.float32)
    x = 0.3 * np.sin(2 * np.pi * 440 * t)
    y = decode(encode_opus(x))
    assert abs(len(y) - len(x)) < SR * 0.05, (len(x), len(y))
    assert process((encode_opus(x), "  hello   world  ", "a"))["text"] == "hello world"
    assert process((encode_opus(x), "", "b")) is None  # empty text dropped
    assert process((encode_opus(x), "x" * 200, "c")) is None  # 100 chars/s: misaligned
    assert process((None, "hi", "d")) is None
    for s in SOURCES:
        assert {"name", "repo", "files", "text", "hours", "license", "style", "split"} <= s.keys(), s["name"]
    print("selftest ok", len(encode_opus(x)), "bytes for 2 s;", len(SOURCES), "sources")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, default=Path.home() / "glide-data")
    p.add_argument("--repo", help="private HF dataset repo, e.g. Stelath/glide-asr-en")
    p.add_argument("--only", nargs="*", help="source names to build")
    p.add_argument("--workers", type=int, default=max(1, mp.cpu_count() - 2))
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    selftest() if a.selftest else build(a.out.expanduser(), a.repo, set(a.only) if a.only else None, a.workers)
