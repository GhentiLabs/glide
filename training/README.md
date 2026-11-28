# Glide training

Dev-time Python for the two models Glide ships: the recognizer (Fluid Speech Pro, a Parakeet TDT 0.6B v3 fine-tune, NeMo) and the
cleanup model (Qwen3.5-0.8B, TRL). The app itself stays Swift with Core ML.

Only public or synthetic data is used here. The user's own dictations never leave the Mac.

## Data (runs on the Mac)

| Script | Output | Private HF repo |
| --- | --- | --- |
| `build_dataset.py` | ~3,000 h English speech, 16 kHz Opus, from `sources.py` | `Stelath/glide-asr-en` |
| `build_cleanup.py` | ~655k spoken → written text pairs, including 34k dictated requests | `Stelath/glide-cleanup-en` |

Both resume where they stopped and have `--selftest`.

## RunPod

```bash
pip install "nemo_toolkit[asr]" trl vllm flash-linear-attention causal-conv1d
hf download Stelath/glide-asr-en --repo-type dataset --local-dir /workspace/glide-asr-en
python asr/prepare_manifests.py /workspace/glide-asr-en /workspace/asr
```

1. **Teacher labels**: serve each teacher with vLLM in turn (Nemotron 3.5 Transcribe needs the NeMo Speech
   setup from its model card; Qwen3-ASR-1.7B needs `pip install qwen-asr`), then
   `python asr/teacher_labels.py transcribe /workspace/asr/train.jsonl nemotron.jsonl --model nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B`,
   the same with `qwen.jsonl --model Qwen/Qwen3-ASR-1.7B`, and
   `python asr/teacher_labels.py merge /workspace/asr/train.jsonl nemotron.jsonl qwen.jsonl /workspace/asr`.
   Where the teachers agree, their text replaces the source label. Where only one agrees with the source label,
   that teacher's text is used. Clips with no agreement are dropped. Some YODAS labels cover only part of their clip;
   relabelling replaces those with the full text.
2. **ASR RL loop, no fine-tune**: `bash asr/rl_loop.sh FluidVoice-Labs/fluid-speech-pro /workspace/asr 5`. Fluid
   Speech Pro loads through the pinned `asr/fluid_speech.py`, since it adds one block a plain NeMo load rejects.
   Each round, `mine_hard.py` transcribes 200k training clips with the newest model and keeps the ones it gets
   wrong (skipping clips where it agrees with a teacher, since their label is in doubt), `grpo_tdt.py` trains on
   them with a second voice mixed into 30% of clips, and the round is kept only if test WER drops. The loop stops
   at the first round that doesn't help. The recognizer stays verbatim: fillers are the cleanup model's job.
   `asr/finetune.py` (supervised fine-tune on the teacher labels) is kept but not part of this plan: on imperfect
   labels it makes the model copy their errors, which RL scored against the same labels mostly avoids.
3. **Cleanup SFT, then GRPO, for each model**: `accelerate launch cleanup/sft.py --model qwen`, then
   `accelerate launch cleanup/grpo.py --model qwen`; repeat with `--model minicpm`. Pick the winner with
   `python cleanup/eval.py qwen-cleanup-grpo minicpm-cleanup-grpo`, then check its speed on the Mac with MLX.
   A large open model rewriting real Parakeet output into clean text is the next data source.

## First RunPod run (25 Nov 2026)

One RTX PRO 6000 for about 6.5 h, $18. Teachers labelled 366k clips (885 h, a third of the training shards);
both agreed on 83%, and 7% were dropped. Five RL rounds from Fluid Speech Pro, each kept:

| | Fluid Speech Pro | Round 5 |
| --- | --- | --- |
| Dev (teacher labels) | 3.47% | 3.20% |
| Dev, YODAS only, fillers removed | 3.95% | 3.67% |
| Test (original labels: Common Voice, LibriSpeech-PC, VoxPopuli) | 6.98% | 7.01% |

The gain is on spontaneous speech (YODAS), which the test set doesn't contain; read speech is unchanged and
VoxPopuli test got slightly worse. Dev clips come from the same videos as training clips, so dev overstates it.
Round 5 is `round-5.nemo` on the `glide-training` network volume and `~/glide-data/models/` on the Mac.

**Decision: Glide keeps Fluid Speech Pro.** A local check found no real gain. It used 1,500 held-out YODAS clips
from shards the run never downloaded and 1,700 of the user's own dictations, with Qwen3-ASR-1.7B (MLX, on the
Mac) as the reference. Dictations scored 7.12% for the base and 7.06% for round 5, fillers ignored, a difference
inside the 95% interval. On YODAS, round 5 scored better against Qwen and worse against the Granary labels by
the same amount. It changed about 10% of clips, and mostly in transcription style: keeping "uh", "gonna" and
spelled-out numbers, and splitting some tech terms. The base already agrees with the teachers on most clips, so
GRPO on public data has little left to learn. The user's own audio, through the on-device loop, is the better
place to look for gains.

## Cleanup run (26 Nov 2026)

One H100 for about 6 h, $26. Each model got SFT on 500k pairs, then 60 GRPO steps (512 prompts × 8), and was scored
on 2,000 test pairs:

| | Reward | Exact | Adds a word |
| --- | --- | --- | --- |
| Qwen3.5-0.8B, base | 0.433 | 18.2% | 49.7% |
| Qwen3.5-0.8B, SFT | 0.978 | 85.2% | 2.1% |
| Qwen3.5-0.8B, SFT + GRPO | 0.977 | 85.1% | 2.4% |
| MiniCPM5-1B, base | 0.033 | 10.5% | 67.2% |
| MiniCPM5-1B, SFT | 0.977 | 84.9% | 2.1% |
| MiniCPM5-1B, SFT + GRPO | 0.977 | 84.8% | 2.2% |

SFT does all the work and GRPO adds nothing. After SFT, 65–76% of GRPO groups gave all eight samples the same
reward, so there was little signal. The two models tie, so Qwen ships: it is smaller. The test pairs come from
the same rule-made pipeline as training, so these scores are an upper bound for real dictation. The SFT and GRPO
models are in `cleanup/` on the `glide-training` network volume.

On the user's 1,707 dictations (Fluid Speech Pro transcripts, Qwen SFT in MLX bf16 on the M1 Pro, run locally),
the model is safe but under-cleans. Among the 1,686 non-empty transcripts, one output added a word, none came out
longer than its input, and none answered a request. But it kept "um" or "uh" in 36 of the 58 transcripts that had
one, removed only 44 of 81 repeated words, and resolved only 1 of 21 spoken corrections ("no wait", "I mean").
On the 21 empty transcripts it invents a sentence, so the app must skip cleanup when the transcript is empty. Its
latency had a median of 0.34 s and a p95 of 1.0 s, at 74 tokens/s. Real fillers and corrections are what the
rule-made pairs miss. The next data source should be teacher rewrites of real Parakeet output.

The app ran the SFT model in MLX, 8-bit (830 MB): it scored the same as bf16 on the dictations, at a 0.24 s median
and 0.73 s p95. It now runs the Core ML split model on the Neural Engine (see Energy, and Swift runtime below). The full-precision SFT and GRPO models are private on Hugging Face (`Stelath/glide-cleanup-qwen3.5-0.8b-*`).

## Core ML probe (27 Nov 2026)

`coreml/` holds the cleanup model rewritten for Core ML (`qwen35.py`), the converter, a greedy harness with copy
speculation (the transcript's own tokens are the guess, checked K at a time) and `patch_lora.py`. It was measured on the
M1 Pro, with made-up sentences only.

- **Exact on the GPU in fp16.** Greedy output matched Hugging Face on all test sentences, plain and speculative. The
  rewrite has fixed shapes, takes K=16 tokens a call, keeps the KV cache and the linear-attention state as Core ML
  state, and uses the chunked gated delta rule with the triangular inverse as 4 matmuls.
- **GPU only: slower than MLX.** 18.7 ms per generated token (K=1) against about 9.5 ms in MLX 8-bit, and 34 ms per
  16-token call. A cleanup took a 358 ms median with speculation (520 ms without), before the prompt cache.
- **8-bit, linear weights only.** Quantizing the embedding, conv or gains as well broke greedy output: it never
  emitted the end token. On the GPU, 8-bit is correct but slower (57 ms per call).
- **On the Neural Engine, after three rewrites.** Each one was needed for the compiler to accept the model, found by
  bisecting with the compiler's log (`ANECompilerService` code 22, MIL→EIR `bad_cast`):
  - no matmul of a tensor with itself (`X @ X`): the inverse's powers are computed as X·(I+X) − X;
  - one Core ML state per layer: two layers updating slices of one stacked state fail;
  - at most 12 layers per model, so the body is two models; the 248k-row embedding and head stay off it. The embedding
    is a row read by the caller, and the head is its own model in vocabulary slices of 15,520 rows.
- **Neural Engine numbers.** Both 12-layer halves run all their ops there. Output matched Hugging Face on every test
  sentence. One 16-token call takes 27.6 ms: 10.9 + 10.2 ms for the 8-bit body halves on the Neural Engine and 6.5 ms
  for the fp16 head on the GPU. 8-bit helps there (fp16 halves take about 13.5 ms each), but not for the head on the
  GPU (10.7 ms). A call costs about the same at K=1 (30.8 ms), so the Neural Engine wants few, full calls.
- **Cleanup latency.** With the shared prompt prefix (68 tokens) cached and copy speculation matched without case or
  punctuation, a cleanup took a 157 ms median and 290 ms at most on five made-up sentences (MLX's 240 ms median was on
  the user's dictations, so these don't compare; see Energy). Python drove these
  runs and copied state through it, so Swift should be a little faster. Power wasn't measured.
- **Load.** The first load compiles for the Neural Engine, about 19 s per half; after that a load takes 0.1 s. A patched
  add-on means one recompile, about 40 s, at night.
- **Patching the add-on works.** LoRA A/B consts stay fp16 under their own names (const deduplication is turned off).
  Overwriting their bytes in `weight.bin` and recompiling (0.75 s) gives the same predictions as torch with the same
  add-on on 281 of 285 positions, the rest being fp16 rounding, while the add-on changed 64 of them. This was checked
  on the single GPU model; the split Neural Engine packages hold the same consts but haven't been patched yet.

## Training probe (27 Nov 2026)

`coreml/train_probe.py` times the nightly LoRA (rank 16, scale 10) on the 8-bit model in MLX, over 64 made-up pairs
on the M1 Pro. MLX Python runs the same kernels as MLX Swift; the model code is still mlx-lm's, with the gated delta
rule swapped for ours.

- **Our chunked gated delta rule makes every layer trainable.** MLX's own linear-attention kernel has no gradient, and
  its reference steps one token at a time. Ours is the chunked form the Core ML model uses, in plain MLX ops: the
  same loss as the reference and gradients within 0.01%, at 276 ms a pair against 856 ms. Chunks of 16 tokens;
  32 and 64 lose fp32 precision on heads with strong decay (layers 5 and 8).
- **The shared prompt runs once per batch.** 68 of a pair's ~105 tokens are the system prompt, the same in every pair.
  Running it once, copying its keys/values and recurrent state to every row and then running only each row's own
  tokens gives the same loss and cuts the work by about 60%.
- **Cap MLX's buffer cache.** Uncapped, batched runs slow down 1.5–2× after the first epoch; at 512 MB they hold steady.
- **Result.** Adapters in all 24 layers, batch 8, shared prompt: **90 ms a pair**, steady over 12 epochs, 4.9 GB peak.
  Today's app trains only the top layer at 104 ms a pair. Caching the frozen lower half (adapters in the top 12 only)
  gave 175 ms at batch 4, and computing the head only on answer tokens saved nothing, so neither is kept.
- **Learning rate.** The app's 1e-3, and 1e-4, make the loss climb with adapters in every layer; 2e-5 is stable.
- **Energy.** One 12-epoch run over 64 pairs (768 pair-steps, 76 s) drew about 16 W above idle, almost all GPU:
  about 1.6 J a pair per epoch. A night of 100 pairs × 5 epochs would be about 0.8 kJ, 0.2 Wh, in under a minute.
- **Not measured yet.** Whether all-layer adapters fix more real edits than the top layer alone; that needs the
  held-out check on the Mac.

## Energy (27 Nov 2026)

`coreml/power.sh` runs each engine for 45 s over made-up sentences under `powermetrics` (sudo; this macOS keeps the
IOReport energy counters frozen for unprivileged processes, and the battery's telemetry updates about once a minute).

| | CPU | GPU | ANE | total | cleanups/s | energy per cleanup above idle |
| --- | --- | --- | --- | --- | --- | --- |
| idle | 2.6 W | 0.2 W | 0 | 2.8 W | | |
| Neural Engine path (Python) | 3.1 W | 1.3 W | 1.4 W | 5.9 W | 3.8 | 0.8 J |
| MLX 8-bit (Python) | 5.5 W | 12.7 W | 0 | 18.2 W | 5.5 | 2.8 J |

- **The whole chip uses about 3.5× less energy per cleanup on the Neural Engine path**, and draws 3.1 W above idle
  while working against 15.4 W for MLX. The GPU's 1.3 W is the head, which runs there.
- A first run showed 9.8 W of CPU during the Neural Engine phase; the benchmark itself used 0.2 of a core, and the
  rerun (with `top` recording the busiest processes) read 3.1 W, so that was other load on the Mac.
- **MLX is faster on the same sentences:** 0.18 s a cleanup on average against 0.26 s. The 157 ms against 240 ms in
  the Core ML probe compared different sets (made-up sentences against the user's dictations), so the Neural Engine
  has no latency win yet; its case is power and leaving the GPU free.

## Swift runtime (28 Nov 2026)

`Cleaner/NeuralEngine.swift` is `harness.py` in Swift: the two 8-bit halves on the Neural Engine, the fp16 head on the
GPU, the embedding read from `embed.bin`, the shared prompt opening run once at load, and copy speculation with the
linear-attention state saved and restored around each guess. It downloads the `.mlpackage`s (1.5 GB with the
embedding) and compiles them on the Mac. On the made-up test sentences it gives the Python runner's output exactly, with
and without guesses. Dictations whose prompt and longest allowed reply pass 512 positions (about 95 words) go out as
transcribed, until the model is reconverted with a larger MAX. MLX is used only for nightly training.

## On-device training (design)

A nightly job on the user's Mac, never uploading anything, trains one small add-on per model from the day's
dictations and corrections:

- **Speech model**: LoRA (rank 16, 11M parameters) on the encoder's attention and feed-forward layers, over Fluid
  Speech Pro's 8-bit MLX weights (751 MB). Training is the same GRPO as on the GPU: sample transcripts, score
  them against the reference with 1 - WER, raise the log-probability of the better ones. It needs no TDT loss,
  which parakeet-mlx doesn't have. `asr/mlx_probe.py` runs one step: on an M1 Pro (16 GB) a 15 s clip takes
  about 2.5 s at 5.5 GB peak, so 200 clips is under 10 minutes, run while the Mac is idle and charging.
- **Cleanup model**: once a day, when macOS finds the Mac idle (`NSBackgroundActivityScheduler`), `Cleaner/Trainer.swift`
  trains a rank-8 LoRA add-on in every projection, in MLX Swift, on the transcript and the text the user kept
  (`Labeller.cleanupPairs`). It trains over the very int8 weights the Neural Engine runs, read from the packages'
  `weight.bin` through `train.json` (written by `coreml/export_train.py`), so nothing extra is downloaded, and it
  predicts the same tokens as the Neural Engine. Every fifth pair is held out. The add-on goes into the LoRA slots of a
  cloned copy of the packages, which is compiled and kept only if it lowers word edits on the held-out pairs. On 20
  made-up pairs from someone who never ends with punctuation, held-out edits went 13 → 1 in 118 s (5 epochs, lr 2e-5)
  in a debug build on an M1 Pro, with free memory never below 25%. MLX's buffer cache is capped at 512 MB and the trainer
  is freed before the tuned model compiles; uncapped, a run grew by gigabytes.
- The two can't train as one network, since text passes between them, but they train from the same log, each
  toward its own target. A new add-on is kept only if it beats the current one on the user's most recent held-out
  dictations, as `rl_loop.sh` does; otherwise it's discarded. Add-ons are small files, so rolling back is free.

Open questions:

- The speech model's reference is what was said, not the cleaned text. The usable signal is words the user
  replaced that the cleanup model didn't change (a misheard name, say); fillers and edits of style don't count.
- The app has to run the recognizer where an add-on can be applied: MLX (Fluid ships an MLX build) takes one at
  load time, while Core ML would need the add-on merged and the model reconverted after every update.
- The app is Swift, so the nightly trainer would be ported to MLX Swift (it has autodiff and optimizers).

What has been checked on the Mac:

- `mine_hard.py` transcribes Opus clips with Fluid Speech Pro (and earlier Parakeet v2), reports WER and writes misses.
- `teacher_labels.py` sends, resumes and merges correctly against a stub server. The real teachers are untested.
- `grpo_tdt.py` samples, scores and updates, on Fluid Speech Pro with its extra block; the second-voice mixing has its own selftest.
  The sampler keeps every tensor on the GPU with fixed shapes and replays its steps as a CUDA graph, and all visited points go
  through the joint in one batch. On the RTX PRO 6000 (shared with a vLLM server) it matches the old code (greedy output
  identical, path log-probs within 3e-7) and takes a GRPO step on 8 clips × 8 samples in 0.23 s instead of 0.78 s; sampling
  alone went from 0.58 s to 0.06 s. Audio for the next batch decodes in a thread while the GPU works. One step raises the log-probability of high-advantage paths (correlation 0.95).
- `finetune.py` reaches the loss. NeMo's TDT loss is CUDA-only.
- `sft.py` and `grpo.py` each complete a training step, and `eval.py` scores a checkpoint.
- `mlx_probe.py` takes one GRPO step on Fluid Speech Pro in MLX with LoRA; gradients are finite and move the right way.

Credit for the recognizer base: "Fluid Speech Pro by FluidVoice. Built on NVIDIA Parakeet TDT 0.6B v3 and Moondream
Parakeet Ultra." (CC BY 4.0).
