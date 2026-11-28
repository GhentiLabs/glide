"""Public English speech sources for the Glide mix. All allow commercial use and have
cased, punctuated transcripts. Licences checked on each dataset card on 2026-11-24.

Left out on purpose: GigaSpeech and SPGISpeech (non-commercial terms), TED-LIUM (NC-ND),
Emilia non-YODAS (NC), People's Speech and MLS (lowercase, no punctuation).
"""

SOURCES: list[dict] = [
    # Spontaneous YouTube speech; Whisper-large-v3 labels with restored punctuation (pseudo-labels).
    dict(name="yodas_granary", repo="espnet/yodas-granary", files="data/en*/asr_only/*.parquet", stride=20,
         text="text", columns=["lang", "task"], keep=lambda r: r["lang"] == "<en>" and r["task"] == "<asr>",
         hours=1600, license="cc-by-3.0", style="spontaneous", split="train"),
    # European Parliament speeches, human transcripts.
    dict(name="voxpopuli", repo="facebook/voxpopuli", files="en/train-*.parquet",
         text="raw_text", columns=["is_gold_transcript"], keep=lambda r: r["is_gold_transcript"],
         hours=450, license="cc0-1.0", style="semi-spontaneous", split="train"),
    # Read prompts, broad accent coverage; only clips the community up-voted.
    dict(name="common_voice", repo="fixie-ai/common_voice_17_0", files="en/train-*.parquet",
         text="sentence", columns=["up_votes", "down_votes"], keep=lambda r: r["up_votes"] >= 2 and r["down_votes"] == 0,
         hours=450, license="cc0-1.0", style="read", split="train"),
    # Audiobooks with the book's own punctuation and casing (LibriSpeech-PC).
    dict(name="librispeech_pc", repo="mythicinfinity/librispeech-pc-44khz-opus", files="all/train.*/*.parquet",
         text="text_raw", hours=500, license="cc-by-4.0", style="read", split="train"),
    # Held-out tests, same sources.
    dict(name="voxpopuli_test", repo="facebook/voxpopuli", files="en/test-*.parquet", text="raw_text",
         hours=5, license="cc0-1.0", style="semi-spontaneous", split="test"),
    dict(name="common_voice_test", repo="fixie-ai/common_voice_17_0", files="en/test-*.parquet", text="sentence",
         hours=5, license="cc0-1.0", style="read", split="test"),
    dict(name="librispeech_pc_test", repo="mythicinfinity/librispeech-pc-44khz-opus", files="all/test.*/*.parquet",
         text="text_raw", hours=10, license="cc-by-4.0", style="read", split="test"),
]
