# Vendored from FluidVoice-Labs/fluid-speech-pro-mlx @ aeb1d4e (CC BY 4.0): "Fluid Speech Pro by FluidVoice.
# Built on NVIDIA Parakeet TDT 0.6B v3 and Moondream Parakeet Ultra." Pinned here so no remote code runs at load time.
"""Run Fluid Speech Pro with parakeet-mlx on Apple Silicon.

Fluid Speech Pro is NVIDIA Parakeet TDT 0.6B v3 with one small extra block between subsampling and the first Conformer
layer. Plain `parakeet_mlx.from_pretrained` stops on these weights ("unexpected encoder.pre_encode.fv_insert") instead
of quietly running without the block; `load()` below adds it and then loads every tensor strictly.

`transcribe()` also computes the audio features exactly the way NeMo does, which this model was scored with.

    from fluid_speech_mlx import load
    model = load("FluidVoice-Labs/fluid-speech-pro-mlx")                      # or a local folder
    model = load("FluidVoice-Labs/fluid-speech-pro-mlx", bits=8)              # 8-bit weights
    model = load("FluidVoice-Labs/fluid-speech-pro-mlx", clean_mode=True)     # drops fillers and repeated words
    print(model.transcribe("audio.wav").text)
"""
import contextlib
import json
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np
import parakeet_mlx.parakeet as parakeet
from mlx.utils import tree_flatten, tree_unflatten
from parakeet_mlx.alignment import sentences_to_result, tokens_to_sentences
from parakeet_mlx.conformer import DwStridingSubsampling
from parakeet_mlx.parakeet import DecodingConfig, ParakeetTDT
from parakeet_mlx.utils import from_config

GROUP_SIZE = 64


class FrameCleaner(nn.Module):
    """Residual block on the subsampled frames: LayerNorm, projection, depthwise time convolution, GELU, projection."""

    def __init__(self, width=1024, dim=1024, kernel=15):
        super().__init__()
        self.ln = nn.LayerNorm(width)
        self.down = nn.Linear(width, dim)
        self.mix = nn.Conv1d(dim, dim, kernel, padding=kernel // 2, groups=dim)
        self.up = nn.Linear(dim, width)

    def __call__(self, x):
        return x + self.up(nn.gelu(self.mix(self.down(self.ln(x)))))


class SubsamplingWithFrameCleaner(DwStridingSubsampling):
    """NeMo's subsampling (which zeroes frames past each layer's valid length, unlike parakeet-mlx's), then the block."""

    def __call__(self, x, lengths):
        lengths = lengths.astype(mx.int32)
        x = x[:, :, :, None]  # [batch, time, mels, channels]
        for layer in self.conv:
            x = x * (mx.arange(x.shape[1])[None, :] < lengths[:, None])[:, :, None, None].astype(x.dtype)
            x = layer(x)
            if isinstance(layer, nn.Conv2d) and layer.stride[0] > 1:
                lengths = (lengths + 2 * self._padding - self._kernel_size) // self._stride + 1
        x = x * (mx.arange(x.shape[1])[None, :] < lengths[:, None])[:, :, None, None].astype(x.dtype)
        x = self.out(x.transpose(0, 1, 3, 2).reshape(x.shape[0], x.shape[1], -1))
        # The block sees every subsampled frame, NeMo's padded one included; the Conformer then sees only real frames.
        x = self.fv_insert(x)
        return x[:, : int(lengths.max())], lengths


def log_mel(audio, args):
    """NeMo's AudioToMelSpectrogramPreprocessor for one clip (dither off): [1, samples // hop + 1, mels], whose last
    frame is NeMo's padded frame (all zeros)."""
    x = mx.array(audio, dtype=mx.float32)
    n_fft, hop, win = args.n_fft, args.hop_length, args.win_length
    valid = x.shape[0] // hop
    if args.preemph is not None:
        x = mx.concatenate([x[:1], x[1:] - args.preemph * x[:-1]])
    x = mx.pad(x, [(n_fft // 2, n_fft // 2)])
    frames = valid + 1
    index = mx.arange(frames)[:, None] * hop + mx.arange(n_fft)[None, :]
    left = (n_fft - win) // 2
    window = mx.array(np.pad(np.hanning(win), (left, n_fft - win - left)), dtype=mx.float32)
    power = mx.abs(mx.fft.rfft(mx.take(x, index) * window)) ** 2
    mel = mx.log(power @ args._filterbanks.T + 2.0**-24)
    real = mel[:valid]
    mean = real.mean(axis=0)
    std = mx.sqrt(((real - mean) ** 2).sum(axis=0) / (valid - 1)) + 1e-5
    mel = (mel - mean) / std
    mel = mx.where(mx.arange(frames)[:, None] < valid, mel, 0.0)
    return mel[None]


@contextlib.contextmanager
def nemo_features():
    stock = parakeet.get_logmel
    parakeet.get_logmel = log_mel
    try:
        yield
    finally:
        parakeet.get_logmel = stock


class FluidSpeechTDT(ParakeetTDT):
    def generate(self, mel, *, decoding_config: DecodingConfig = DecodingConfig()):
        if mel.ndim == 2:
            mel = mel[None]
        lengths = None
        if mel.shape[1] > 1 and bool(mx.all(mel[:, -1, :] == 0)):
            lengths = mx.full((mel.shape[0],), mel.shape[1] - 1, dtype=mx.int64)  # NeMo's layout: one padded frame
        features, lengths = self.encoder(mel, lengths)
        mx.eval(features, lengths)
        result, _ = self.decode(features, lengths, config=decoding_config)
        return [sentences_to_result(tokens_to_sentences(h, decoding_config.sentence)) for h in result]

    def transcribe(self, path, **kwargs):
        with nemo_features():
            return super().transcribe(path, **kwargs)

    def transcribe_stream(self, *args, **kwargs):
        raise NotImplementedError("Fluid Speech Pro runs offline only: its extra block looks 7 frames ahead.")


class LowRankAdded(nn.Module):
    """A quantized layer plus clean mode's low-rank update, which can't be folded into 8-bit weights."""

    def __init__(self, base, a, b):
        super().__init__()
        self.base = base
        self.a = a
        self.b = b

    def __call__(self, x):
        return self.base(x) + (x @ self.a.T) @ self.b.T


def add_clean_mode(net, adapter, scale):
    """Clean mode: add scale * B @ A to every adapted encoder layer, and its two input vectors to the biases they meet."""
    lstm = net.decoder.prediction["dec_rnn"].lstm[0]
    lstm.bias = lstm.bias + lstm.Wx.astype(mx.float32) @ adapter.pop("decoder_input")
    net.joint.pred.bias = net.joint.pred.bias + adapter.pop("joint_hidden")
    for name in sorted({k.rsplit(".", 1)[0] for k in adapter}):
        a, b = adapter[f"{name}.A"], scale * adapter[f"{name}.B"]
        *path, child = ("encoder." + name).split(".")
        parent = net
        for part in path:
            parent = parent[int(part)] if part.isdigit() else getattr(parent, part)
        layer = getattr(parent, child)
        if isinstance(layer, nn.QuantizedLinear):
            setattr(parent, child, LowRankAdded(layer, a, b))
        else:
            layer.weight = layer.weight.astype(mx.float32) + (b @ a).reshape(layer.weight.shape)


def weights_name(bits=None):
    return "model" + (f".{bits}bit" if bits else "") + ".safetensors"


def load(model="FluidVoice-Labs/fluid-speech-pro-mlx", *, clean_mode=False, bits=None, dtype=mx.bfloat16):
    name = weights_name(bits)
    files = ["config.json", name] + (["clean-mode.safetensors"] if clean_mode else [])
    folder = Path(model)
    if not folder.is_dir():
        from huggingface_hub import snapshot_download
        folder = Path(snapshot_download(model, allow_patterns=files))
    config = json.loads((folder / "config.json").read_text())

    net = from_config(config)
    assert type(net) is ParakeetTDT, f"expected a TDT model, got {type(net).__name__}"
    net.__class__ = FluidSpeechTDT
    pre = net.encoder.pre_encode
    pre.__class__ = SubsamplingWithFrameCleaner
    spec = config["fluid_speech"]
    pre.fv_insert = FrameCleaner(config["encoder"]["d_model"], spec["insert_dim"], spec["insert_kernel"])
    if bits:
        nn.quantize(net, group_size=GROUP_SIZE, bits=bits, class_predicate=lambda _, m: isinstance(m, nn.Linear))
    net.load_weights(str(folder / name))
    if clean_mode:
        adapter = {k: v.astype(mx.float32) for k, v in mx.load(str(folder / "clean-mode.safetensors")).items()}
        add_clean_mode(net, adapter, spec["clean_mode"]["alpha"] / spec["clean_mode"]["rank"])

    params = [(k, v.astype(dtype) if mx.issubdtype(v.dtype, mx.floating) else v) for k, v in tree_flatten(net.parameters())]
    net.update(tree_unflatten(params))
    net.eval()
    return net
