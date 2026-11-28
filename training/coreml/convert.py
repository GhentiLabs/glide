"""Converts the cleanup model to stateful Core ML packages, fp16 or 8-bit linear weights, LoRA slots kept in fp16.

    python convert.py <hf_model_dir> <out_prefix> [K] [MAX] [bits: 8 or 16]

Writes <out_prefix>-body0/-body1.mlpackage (layers 0-11 and 12-23 with their state; the Neural Engine takes at most 12) and
<out_prefix>-head.mlpackage (hidden states to the greedy next token). The embedding lookup is a row read the app does
itself, from the same matrix as the head.
"""

import functools
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

from qwen35 import Qwen35, inputs_for


class Head(nn.Module):
    """Greedy next token, in vocabulary slices of at most 16384 rows, the Neural Engine's limit."""

    def __init__(self, embed: torch.Tensor, rows: int = 15520):
        super().__init__()
        self.rows = rows
        self.parts = nn.ParameterList([nn.Parameter(p, requires_grad=False) for p in embed.split(rows)])

    def forward(self, h):
        best, where = [], []
        for p in self.parts:
            v, i = F.linear(h, p).max(-1)
            best.append(v)
            where.append(i)
        best, where = torch.stack(best, -1), torch.stack(where, -1)                     # [K, parts]
        part = best.argmax(-1, keepdim=True)
        return (where.gather(-1, part).squeeze(-1) + part.squeeze(-1) * self.rows).to(torch.int32).unsqueeze(0)


def save(ml, out, bits, lora=()):
    consts = [op for f in ml._mil_program.functions.values() for op in f.operations if op.op_type == "const"]
    # Only weights read by linear ops: 8-bit embeddings, convs and gains broke greedy output (it never stopped).
    skip = set(lora) | {op.name for op in consts if {c.op_type for c in op.outputs[0].child_ops} != {"linear"}}
    if bits == 8:
        cfg = ct.optimize.coreml.OptimizationConfig(
            global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel"),
            op_name_configs={n: None for n in skip})
        ml = ct.optimize.coreml.linear_quantize_weights(ml, cfg)
    ml.save(out)


def convert(model_dir, prefix, K=16, MAX=512, bits=16):
    m = Qwen35(model_dir, K=K, MAX=MAX).eval()
    np.save(f"{prefix}-embed.npy", m.embed.detach().numpy().astype(np.float16))

    ex = (torch.zeros(K, m.embed.shape[1]), *inputs_for(list(range(K)), K, K, MAX))
    names = ["x", "cos", "sin", "mask", "write", "active", "pick"]
    inputs = [ct.TensorType(name=n, shape=t.shape, dtype=np.float16) for n, t in zip(names, ex)]
    # Identical consts get merged by default, which would make the per-layer LoRA slots share one blob.
    pipeline = ct.PassPipeline.DEFAULT
    pipeline.remove_passes(["common::const_deduplication"])
    n_lora = 0
    for part, (start, stop) in enumerate([(0, 12), (12, len(m.layers))]):
        m.forward = functools.partial(m.body, start=start, stop=stop)
        with torch.no_grad():
            traced = torch.jit.trace(m, ex)
        states = [ct.StateType(wrapped_type=ct.TensorType(shape=getattr(m, n).shape, dtype=np.float16), name=n)
                  for n in m.states_in(start, stop)]
        ml = ct.convert(traced, inputs=inputs, states=states, outputs=[ct.TensorType(name="h", dtype=np.float16)],
                        minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16,
                        pass_pipeline=pipeline, skip_model_load=True)
        lora = [op.name for f in ml._mil_program.functions.values() for op in f.operations if op.op_type == "const" and "lora" in op.name]
        n_lora += len(lora)
        save(ml, f"{prefix}-body{part}.mlpackage", bits, lora)

    head = Head(m.embed.detach()).eval()
    with torch.no_grad():
        traced = torch.jit.trace(head, (torch.zeros(K, m.embed.shape[1]),))
    ml = ct.convert(traced, inputs=[ct.TensorType(name="h", shape=(K, m.embed.shape[1]), dtype=np.float16)],
                    outputs=[ct.TensorType(name="next", dtype=np.int32)], minimum_deployment_target=ct.target.macOS15,
                    compute_precision=ct.precision.FLOAT16, skip_model_load=True)
    save(ml, f"{prefix}-head.mlpackage", bits)
    print(f"saved {prefix}-body0/-body1/-head.mlpackage and -embed.npy: {n_lora} LoRA consts left in fp16")


if __name__ == "__main__":
    a = sys.argv
    convert(a[1], a[2], *(int(x) for x in a[3:6]))
