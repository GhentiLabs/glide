"""Feasibility probe for on-device training: one GRPO step on Fluid Speech Pro in MLX, LoRA on the encoder
over the 8-bit weights. GRPO only needs log-probs of sampled paths, so no TDT loss is needed (parakeet-mlx has
none, and NeMo's is CUDA-only).

Measures time and peak memory for 4 sampled TDT paths on one clip, and checks the gradient is finite and that
one step raises the log-probability of the highest-advantage path. The reward is a stand-in (path length):
this checks the mechanics, not learning.

    uv run --with parakeet-mlx --with soundfile python asr/mlx_probe.py clip.opus

M1 Pro, 16 GB, 15 s clip: 0.6 s to sample 4 paths, 1.7 s for the gradient step, 5.5 GB peak.
"""
import sys
import time

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import numpy as np
import soundfile as sf
from mlx.utils import tree_flatten

from fluid_speech_mlx import load, log_mel


class LoRA(nn.Module):
    def __init__(self, base, r=16, alpha=32):
        super().__init__()
        d_in = base.weight.shape[1] * (32 // base.bits) if isinstance(base, nn.QuantizedLinear) else base.weight.shape[1]
        d_out = base.weight.shape[0]
        self.base, self.scale = base, alpha / r
        self.a = mx.random.normal((r, d_in)) * (1 / d_in) ** 0.5
        self.b = mx.zeros((d_out, r))

    def __call__(self, x):
        return self.base(x) + self.scale * ((x @ self.a.T) @ self.b.T)


def add_lora(net):
    for layer in net.encoder.layers:
        for mod, names in [(layer.self_attn, ["linear_q", "linear_k", "linear_v", "linear_out"]),
                           (layer.feed_forward1, ["linear1", "linear2"]), (layer.feed_forward2, ["linear1", "linear2"])]:
            for n in names:
                setattr(mod, n, LoRA(getattr(mod, n)))
    net.freeze()
    for layer in net.encoder.layers:
        for mod in (layer.self_attn, layer.feed_forward1, layer.feed_forward2):
            for child in mod.children().values():
                if isinstance(child, LoRA):
                    child.unfreeze(keys=["a", "b"], recurse=False)


def sample_path(net, feats, length, rng):
    """Sample one TDT path: list of (t, u, token, duration_index)."""
    blank, durs = len(net.vocabulary), net.durations
    path, tokens, state, last, t = [], [], None, None, 0
    emitted_here = 0
    while t < length:
        out, new_state = net.decoder(mx.array([[last]]) if last is not None else None, state)
        logits = net.joint(feats[:, t:t + 1], out.astype(feats.dtype))[0, 0, 0].astype(mx.float32)
        tok = int(mx.random.categorical(logits[:blank + 1], key=rng()))
        d_logits = logits[blank + 1:]
        if tok == blank:
            d_logits = mx.where(mx.array(durs) == 0, -mx.inf, d_logits)
        d = int(mx.random.categorical(d_logits, key=rng()))
        path.append((t, len(tokens), tok, d))
        if tok != blank:
            tokens.append(tok)
            last, state = tok, new_state
        emitted_here = emitted_here + 1 if durs[d] == 0 else 0
        t += durs[d] if emitted_here < 10 else max(durs[d], 1)
    return path, tokens


def path_logp(net, mel, lengths, path, tokens):
    feats, _ = net.encoder(mel, lengths)
    out, st = net.decoder(None, None)
    preds = [out]
    for tk in tokens:  # parakeet-mlx's LSTM wrapper is only right one step at a time (it swaps batch and time)
        out, st = net.decoder(mx.array([[tk]]), st)
        preds.append(out)
    pred = mx.concatenate(preds, axis=1).astype(feats.dtype)  # [1, U+1, H]
    t_idx = mx.array([p[0] for p in path]); u_idx = mx.array([p[1] for p in path])
    enc = net.joint.enc(feats[0, t_idx]); pr = net.joint.pred(pred[0, u_idx])
    x = enc + pr
    for layer in net.joint.joint_net:
        x = layer(x)
    x = x.astype(mx.float32)
    blank = len(net.vocabulary)
    tok = mx.array([p[2] for p in path]); dur = mx.array([p[3] for p in path])
    tok_lp = nn.log_softmax(x[:, :blank + 1], axis=-1)[mx.arange(len(path)), tok]
    d_logits = x[:, blank + 1:]
    zero = (mx.array(net.durations) == 0)[None, :] & (tok == blank)[:, None]
    d_lp = nn.log_softmax(mx.where(zero, -mx.inf, d_logits), axis=-1)[mx.arange(len(path)), dur]
    return (tok_lp + d_lp).sum()


def main():
    audio, sr = sf.read(sys.argv[1], dtype="float32")
    audio = audio[: 15 * sr]
    net = load("FluidVoice-Labs/fluid-speech-pro-mlx", bits=8)
    add_lora(net)
    n_train = sum(v.size for _, v in tree_flatten(net.trainable_parameters()))
    print(f"trainable LoRA params: {n_train / 1e6:.1f}M, clip {len(audio) / sr:.1f} s")
    mel = log_mel(audio, net.preprocessor_config).astype(mx.bfloat16)
    lengths = mx.array([mel.shape[1] - 1])
    seed = iter(range(10_000))
    rng = lambda: mx.random.key(next(seed))

    mx.reset_peak_memory()
    t0 = time.time()
    feats, flen = net.encoder(mel, lengths)
    mx.eval(feats)
    paths = [sample_path(net, feats, int(flen[0]), rng) for _ in range(4)]
    t_sample = time.time() - t0
    lens = [len(tk) for _, tk in paths]
    adv = mx.array(lens, dtype=mx.float32); adv = adv - adv.mean()  # stand-in reward: any spread works for the probe

    def loss_fn(model):
        return -sum(adv[i] * path_logp(model, mel, lengths, p, tk) for i, (p, tk) in enumerate(paths)) / len(paths)

    best = int(mx.argmax(adv))
    before = path_logp(net, mel, lengths, *paths[best]).item()
    opt = optim.Adam(learning_rate=1e-5)
    t1 = time.time()
    loss, grads = nn.value_and_grad(net, loss_fn)(net)
    opt.update(net, grads)
    mx.eval(net.parameters(), opt.state, loss)
    t_step = time.time() - t1
    after = path_logp(net, mel, lengths, *paths[best]).item()
    gnorm = sum(float((g * g).sum()) for _, g in tree_flatten(grads)) ** 0.5
    print(f"sample 4 paths: {t_sample:.1f} s (tokens per path {lens}); grad step: {t_step:.1f} s")
    print(f"peak memory {mx.get_peak_memory() / 2**30:.2f} GB; grad norm {gnorm:.3g}; "
          f"best-path log-prob {before:.2f} -> {after:.2f}")
    assert np.isfinite(gnorm) and gnorm > 0 and after > before
    print("probe ok")


main()
