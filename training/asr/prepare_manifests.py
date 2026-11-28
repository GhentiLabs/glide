"""Unpack build_dataset.py parquet shards into opus files + NeMo manifests (one JSON line per clip).

    hf download Stelath/glide-asr-en --repo-type dataset --local-dir /workspace/glide-asr-en
    python training/asr/prepare_manifests.py /workspace/glide-asr-en /workspace/asr
"""

import json
import sys
from pathlib import Path

import pyarrow.parquet as pq

src, out = Path(sys.argv[1]), Path(sys.argv[2])
limit = int(sys.argv[3]) if len(sys.argv) > 3 else None  # clips per split, for smoke tests
out.mkdir(parents=True, exist_ok=True)
for split_dir in sorted((src / "data").iterdir()):
    rows, n = {}, 0
    for shard in sorted(split_dir.glob("*.parquet")):
        for r in pq.read_table(shard, columns=["id", "audio", "text", "duration", "source"]).to_pylist():
            path = out / "audio" / r["source"] / f"{r['id']}.opus"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(r["audio"]["bytes"])
            # Builds before the id fix reuse ids across source folders; the last clip written owns the file
            rows[str(path)] = {"audio_filepath": str(path), "duration": r["duration"], "text": r["text"], "source": r["source"]}
            n += 1
            if limit and n >= limit:
                break
        if limit and n >= limit:
            break
    with open(out / f"{split_dir.name}.jsonl", "w") as man:
        man.writelines(json.dumps(r) + "\n" for r in rows.values())
    print(f"{split_dir.name}: {len(rows)} clips ({n - len(rows)} lost to repeated ids), {sum(r['duration'] for r in rows.values()) / 3600:.1f} h")
