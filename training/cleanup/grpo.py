"""GRPO for the cleanup model, with the Fish Audio Drama 3 settings that carry over:
Dr. GRPO mean-centred advantages, no KL and no reference model, temperature 1 with no
top-p, asymmetric clip 0.2 / 0.28, large batches with one optimizer step each, a small
constant learning rate, and a length cap by budget.

    accelerate launch training/cleanup/grpo.py --model qwen      # RunPod, starts from qwen-cleanup-sft
    python training/cleanup/grpo.py --max_steps 1 --prompts 2 --G 2        # smoke test, Mac
"""

import argparse

import torch
from transformers import AutoTokenizer
from trl import GRPOConfig, GRPOTrainer

from common import MODELS, load_pairs
from rewards import reward_fn

p = argparse.ArgumentParser()
p.add_argument("--model", choices=MODELS, default="qwen")
p.add_argument("--init", help="checkpoint to start from; defaults to <model>-cleanup-sft")
p.add_argument("--out", help="defaults to <model>-cleanup-grpo")
p.add_argument("--max_steps", type=int, default=60)
p.add_argument("--prompts", type=int, default=512, help="prompts per optimizer step (Drama 3 used 1,536)")
p.add_argument("--G", type=int, default=8)
a = p.parse_args()
init, out = a.init or f"{a.model}-cleanup-sft", a.out or f"{a.model}-cleanup-grpo"

tok = AutoTokenizer.from_pretrained(MODELS[a.model])
cuda = torch.cuda.is_available()
world = torch.cuda.device_count() or 1
per_device = 16 if cuda else a.prompts * a.G
cfg = GRPOConfig(
    output_dir=out, max_steps=a.max_steps, report_to="none", logging_steps=1,
    loss_type="dr_grpo", scale_rewards="none", beta=0.0,
    num_generations=a.G, temperature=1.0, top_p=1.0, epsilon=0.2, epsilon_high=0.28,
    max_completion_length=256, mask_truncated_completions=True,
    per_device_train_batch_size=per_device,
    gradient_accumulation_steps=max(1, a.prompts * a.G // (per_device * world)),
    # roll out 1,024 at a time: vLLM at 30% of an H100 fits 1,717 Qwen3.5 sequences (one Mamba block each), not 4,096.
    # Weights only change at the optimizer step, so every rollout in a step still comes from the same policy.
    steps_per_generation=min(64, max(1, a.prompts * a.G // (per_device * world))),
    num_iterations=1,  # each rollout batch is used for exactly one step
    learning_rate=1e-6, lr_scheduler_type="constant", weight_decay=0.0,
    bf16=cuda, gradient_checkpointing=True,
    use_vllm=cuda, vllm_mode="colocate", vllm_gpu_memory_utilization=0.3,
)
trainer = GRPOTrainer(model=init, reward_funcs=reward_fn, args=cfg,
            train_dataset=load_pairs(tok, "train", skip=500_000), processing_class=tok)
trainer.train()
trainer.save_model(out)
