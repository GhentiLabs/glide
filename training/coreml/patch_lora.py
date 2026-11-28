"""Writes LoRA weights into a converted package's weight.bin in place; the app does the same in Swift each night.

Each LoRA const is a fp16 blob. Its BLOBFILE offset points at a 64-byte header:
    uint32 sentinel 0xDEADBEEF, uint32 dtype, uint64 size in bytes, uint64 data offset, padding.
"""

import struct

import coremltools as ct
import numpy as np


def lora_blobs(package):
    """{const name: (header offset, shape)} for every LoRA const."""
    spec = ct.utils.load_spec(package)
    fn = spec.mlProgram.functions["main"]
    out = {}
    for op in fn.block_specializations[fn.opset].operations:
        if op.type != "const" or not op.outputs:
            continue
        name = op.outputs[0].name
        if "lora" in name:
            v = op.attributes["val"]
            out[name] = (v.blobFileValue.offset, tuple(d.constant.size for d in v.type.tensorType.dimensions))
    return out


def write(package, values):
    """values: {const name: np.ndarray}, each the shape stored in the package."""
    blobs = lora_blobs(package)
    with open(f"{package}/Data/com.apple.CoreML/weights/weight.bin", "r+b") as f:
        for name, arr in values.items():
            header, shape = blobs[name]
            f.seek(header)
            sentinel, _dtype, size, data = struct.unpack("<IIQQ", f.read(24))
            assert sentinel == 0xDEADBEEF, name
            raw = np.ascontiguousarray(arr, dtype=np.float16).reshape(shape).tobytes()
            assert len(raw) == size, (name, len(raw), size)
            f.seek(data)
            f.write(raw)
