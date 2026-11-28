"""Full fine-tune of the cleanup model on rule-made and (later) teacher-made pairs.

    accelerate launch training/cleanup/sft.py --model qwen     # RunPod, all GPUs; then --model minicpm
    python training/cleanup/sft.py --max_steps 3 --bs 2         # smoke test, Mac
"""

import argparse
from pathlib import Path

import torch
from huggingface_hub import snapshot_download
from transformers import AutoTokenizer
from trl import SFTConfig, SFTTrainer

from common import MODELS, load_pairs, turn_end

p = argparse.ArgumentParser()
p.add_argument("--model", choices=MODELS, default="qwen")
p.add_argument("--out", help="defaults to <model>-cleanup-sft")
p.add_argument("--max_steps", type=int, default=-1)
p.add_argument("--bs", type=int, default=64)
p.add_argument("--sft_rows", type=int, default=500_000, help="the rest of train is left for GRPO")
a = p.parse_args()
model, out = MODELS[a.model], a.out or f"{a.model}-cleanup-sft"

tok = AutoTokenizer.from_pretrained(model)
cuda = torch.cuda.is_available()
cfg = SFTConfig(
    output_dir=out, max_steps=a.max_steps, num_train_epochs=1, per_device_train_batch_size=a.bs,
    learning_rate=1e-5, lr_scheduler_type="cosine", warmup_steps=200, weight_decay=0.0,
    bf16=cuda, max_length=512, completion_only_loss=True, eos_token=turn_end(tok),
    gradient_checkpointing=True, logging_steps=10, save_strategy="steps", save_steps=1000, save_total_limit=1, report_to="none",  # ~10 GB each with optimizer state
)
trainer = SFTTrainer(model=model, args=cfg, train_dataset=load_pairs(tok, "train", limit=a.sft_rows),
           eval_dataset=load_pairs(tok, "test", limit=500), processing_class=tok)
trainer.train(resume_from_checkpoint=any(Path(out).glob("checkpoint-*")) or None)  # True resumes from the latest
trainer.save_model(out)
# vLLM (GRPO rollouts) loads Qwen3.5 as multimodal and refuses a checkpoint without its image-processor config
snapshot_download(model, allow_patterns=["*preprocessor_config.json"], local_dir=out)
