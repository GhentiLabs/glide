"""Writes what the app's nightly trainer needs next to the converted packages, so it trains on the very weights the
Neural Engine runs and nothing else is downloaded:

  train.json         where each projection's int8 weight, per-row scale and LoRA A/B sit in body0/body1 weight.bin
  train.safetensors  the small fp32 parameters: norms, convs, decay and gate projections

    python export_train.py <hf_model_dir> <package_dir>     (package_dir holds body0.mlpackage and body1.mlpackage)
"""

import json
import struct
import sys

import coremltools as ct
import numpy as np
import torch
from safetensors.numpy import save_file

from qwen35 import Qwen35

PROJ = {"full_attention": ["q_proj", "k_proj", "v_proj", "o_proj"], "linear_attention": ["in_proj_qkv", "in_proj_z", "out_proj"]}
MLP = ["gate_proj", "up_proj", "down_proj"]


def blobs(package):
    """{const name: data offset in weight.bin} for every blob-backed const, and {quantized weight: (data, scale) names}."""
    spec = ct.utils.load_spec(package)
    fn = spec.mlProgram.functions["main"]
    ops = fn.block_specializations[fn.opset].operations
    path = f"{package}/Data/com.apple.CoreML/weights/weight.bin"
    offsets = {}
    with open(path, "rb") as f:
        for op in ops:
            if op.type == "const" and op.attributes["val"].WhichOneof("value") == "blobFileValue":
                f.seek(op.attributes["val"].blobFileValue.offset)
                sentinel, _dtype, _size, data = struct.unpack("<IIQQ", f.read(24))
                assert sentinel == 0xDEADBEEF, op.outputs[0].name
                offsets[op.outputs[0].name] = data
            # the quantized weight's data and scale are inline arguments rather than separate const ops
            if op.type == "constexpr_blockwise_shift_scale":
                for key in ("data", "scale"):
                    value = op.inputs[key].arguments[0].value
                    f.seek(value.blobFileValue.offset)
                    sentinel, _dtype, _size, data = struct.unpack("<IIQQ", f.read(24))
                    assert sentinel == 0xDEADBEEF, op.outputs[0].name
                    offsets[f"{op.outputs[0].name}/{key}"] = data
    return offsets, path


def export(model_dir, package_dir):
    m = Qwen35(model_dir, K=16, MAX=512)
    parts = [blobs(f"{package_dir}/body{i}.mlpackage") for i in (0, 1)]
    layers, small = [], {"norm": m.norm}
    for i, (L, t) in enumerate(zip(m.layers, m.types)):
        offsets, path = parts[0 if i < 12 else 1]
        entry = {"type": t, "part": 0 if i < 12 else 1, "proj": {}}
        for name in PROJ[t] + MLP:
            w = getattr(L, name).weight
            q, s = offsets[f"layers_{i}_{name}_weight_to_fp16_quantized/data"], offsets[f"layers_{i}_{name}_weight_to_fp16_quantized/scale"]
            entry["proj"][name] = {"shape": list(w.shape), "weight": q, "scale": s,
                                   "lora_a": offsets[f"layers_{i}_{name}_lora_a_to_fp16"],
                                   "lora_b": offsets[f"layers_{i}_{name}_lora_b_to_fp16"]}
            # The int8 rows times their scale must give back the model's weight.
            raw = np.fromfile(path, np.int8, w.numel(), offset=q).reshape(w.shape).astype(np.float32)
            scale = np.fromfile(path, np.float16, w.shape[0], offset=s).astype(np.float32)[:, None]
            err = np.abs(raw * scale - w.detach().numpy()).max() / np.abs(w.detach().numpy()).max()
            assert err < 0.01, (i, name, err)
        layers.append(entry)
        p = f"layers.{i}."
        small[p + "ln1"], small[p + "ln2"] = L.ln1, L.ln2
        names = ["q_norm", "k_norm"] if t == "full_attention" else ["in_proj_b", "in_proj_a", "conv", "dt_bias", "A", "gnorm"]
        for n in names:
            small[p + n] = getattr(L, n)
    # Every LoRA slot is its own blob; a shared one would carry one projection's add-on into another.
    slots = [v for e in layers for pr in e["proj"].values() for v in (pr["lora_a"], pr["lora_b"])]
    pairs = [(e["part"], v) for e in layers for pr in e["proj"].values() for v in (pr["lora_a"], pr["lora_b"])]
    assert len(set(pairs)) == len(slots), "LoRA slots share blobs: reconvert with convert.py"
    cfg = {"layers": layers, "rank": int(m.layers[0].gate_proj.lora_a.shape[0]), "heads": m.heads, "kv_heads": m.kv_heads,
           "head_dim": m.hd, "linear_heads": m.vh, "linear_key_heads": m.kh, "key_dim": m.dk, "value_dim": m.dv, "eps": m.eps}
    json.dump(cfg, open(f"{package_dir}/train.json", "w"))
    save_file({k: v.detach().float().contiguous().numpy() for k, v in small.items()}, f"{package_dir}/train.safetensors")
    print(f"wrote train.json ({len(layers)} layers, {len(slots)} LoRA slots) and train.safetensors ({len(small)} tensors)")


if __name__ == "__main__":
    with torch.no_grad():
        export(sys.argv[1], sys.argv[2])
