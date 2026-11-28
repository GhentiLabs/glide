"""Full fine-tune of Fluid Speech Pro (a Parakeet TDT 0.6B v3 fine-tune) on the Glide mix (NeMo + Lightning, DDP, bf16).

A 0.6B model fits on one GPU, so Megatron-style tensor or pipeline parallelism would only
add communication. Throughput comes from Lhotse duration bucketing (almost no padding),
per-bucket batch sizes found with NeMo's OOMptimizer, bf16, and enough data workers.

    torchrun --nproc_per_node 8 training/asr/finetune.py --train /workspace/asr/train.jsonl --val /workspace/asr/test.jsonl
    python training/asr/finetune.py --train m.jsonl --val m.jsonl --smoke     # CPU, 2 steps
"""

import argparse

import lightning.pytorch as pl
import torch
from omegaconf import open_dict

import fluid_speech

p = argparse.ArgumentParser()
p.add_argument("--model", default="FluidVoice-Labs/fluid-speech-pro", help="Hub id or .nemo")
p.add_argument("--train", required=True)
p.add_argument("--val", required=True)
p.add_argument("--out", default="parakeet-glide-sft.nemo")
p.add_argument("--steps", type=int, default=60_000)
p.add_argument("--lr", type=float, default=5e-5)
p.add_argument("--batch_duration", type=float, default=900, help="seconds of audio per GPU batch (H100 80 GB)")
p.add_argument("--bucket_batch_size", type=int, nargs="*", help="per-bucket batch sizes from OOMptimizer; overrides batch_duration")
p.add_argument("--smoke", action="store_true")
a = p.parse_args()

model = fluid_speech.load(a.model)
with open_dict(model.cfg):
    tr = model.cfg.train_ds
    tr.manifest_filepath, tr.text_field, tr.num_workers = a.train, "text", 0 if a.smoke else 12
    tr.use_bucketing, tr.num_buckets, tr.max_duration = not a.smoke, 30, 40.0
    tr.batch_duration = None if a.bucket_batch_size else (8 if a.smoke else a.batch_duration)
    if a.bucket_batch_size:
        tr.bucket_batch_size = a.bucket_batch_size
    va = model.cfg.validation_ds
    va.manifest_filepath, va.text_field, va.batch_size, va.num_workers = a.val, "text", 2 if a.smoke else 32, 0 if a.smoke else 4
    model.cfg.optim.lr = a.lr
    model.cfg.optim.weight_decay = 1e-3
    model.cfg.optim.sched.warmup_steps = 0 if a.smoke else 2_000
    model.cfg.optim.sched.min_lr = a.lr / 50
    model.cfg.optim.sched.max_steps = a.steps
model.setup_training_data(model.cfg.train_ds)
model.setup_validation_data(model.cfg.validation_ds)
model.setup_optimization(model.cfg.optim)

gpu = torch.cuda.is_available()
trainer = pl.Trainer(
    accelerator="gpu" if gpu else "cpu", devices=-1 if gpu else 1, strategy="ddp" if gpu else "auto",
    precision="bf16-mixed" if gpu else 32, max_steps=2 if a.smoke else a.steps,
    limit_val_batches=1 if a.smoke else 1.0, val_check_interval=2 if a.smoke else 2_000,
    gradient_clip_val=1.0, use_distributed_sampler=False,  # Lhotse shards data per rank itself
    logger=False, enable_checkpointing=not a.smoke, log_every_n_steps=1 if a.smoke else 50,
)
model.set_trainer(trainer)
trainer.fit(model)
model.save_to(a.out)
