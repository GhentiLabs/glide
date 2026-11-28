"""How fast can the nightly cleanup LoRA train? Times one epoch over made-up pairs on the 8-bit model in MLX
under different setups, and checks the chunked gated-delta rule against MLX's sequential reference.

  ~/glide-data/eval/mlx/bin/python train_probe.py         # parity check
  ~/glide-data/eval/mlx/bin/python train_probe.py N       # setup N of TRIALS
"""

import os
import random
import sys
import time

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import numpy as np
from mlx.utils import tree_flatten
from mlx_lm import load
from mlx_lm.models import gated_delta, qwen3_5
from mlx_lm.tuner.utils import linear_to_lora_layers

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import SYSTEM

MODEL = os.path.expanduser("~/glide-data/models/glide-cleanup-mlx-8bit")
CHUNK = 16  # 32 and 64 lose precision in fp32 on heads with strong decay (layers 5 and 8)


def chunked_delta(q, k, v, log_g, beta, state):
    """The gated delta rule over whole chunks of tokens (UT/WY form): a few matmuls per 16 tokens instead of one
    step per token, so its gradient is a short graph too. Shapes as MLX: q, k [B,T,H,Dk]; v [B,T,H,Dv];
    log_g, beta [B,T,H]; state [B,H,Dv,Dk]."""
    B, T, H, Dk = q.shape
    Dv, dtype = v.shape[-1], v.dtype
    assert v.shape[2] == H, "expects as many key heads as value heads"
    pad = -T % CHUNK
    if pad:  # zero k, v and beta, and log decay 0, leave the state untouched
        q, k, v = (mx.pad(t, [(0, 0), (0, pad), (0, 0), (0, 0)]) for t in (q, k, v))
        log_g, beta = (mx.pad(t, [(0, 0), (0, pad), (0, 0)]) for t in (log_g, beta))
    N = (T + pad) // CHUNK
    f32 = lambda t: t.astype(mx.float32)
    # [B,H,N,C,D]
    q, k, v = (f32(t).transpose(0, 2, 1, 3).reshape(B, H, N, CHUNK, -1) for t in (q, k, v))
    log_g, beta = (f32(t).transpose(0, 2, 1).reshape(B, H, N, CHUNK) for t in (log_g, beta))
    c = mx.cumsum(log_g, axis=-1)  # decay from chunk start through each token
    lower = mx.tril(mx.ones((CHUNK, CHUNK)), -1)
    decay = mx.exp(mx.minimum(c[..., :, None] - c[..., None, :], 0)) * lower  # i>j: decay from j to i
    kb = k * beta[..., None]
    A = (kb @ k.swapaxes(-1, -2)) * decay
    # (I + A)^-1 for strictly lower A: (I - A)(I + A^2)(I + A^4)(I + A^8)
    eye = mx.eye(CHUNK)
    inv, p = eye - A, A @ A
    for _ in range(CHUNK.bit_length() - 2):
        inv = inv @ (eye + p)
        p = p @ p
    u = inv @ (v * beta[..., None])
    w = inv @ (kb * mx.exp(c)[..., None])
    causal = mx.tril(mx.ones((CHUNK, CHUNK)))
    qk = (q @ k.swapaxes(-1, -2)) * (decay + eye) * causal
    S = f32(state)  # [B,H,Dv,Dk]
    out = []
    for n in range(N):
        St = S.swapaxes(-1, -2)  # [B,H,Dk,Dv]
        v_new = u[:, :, n] - w[:, :, n] @ St
        out.append((q[:, :, n] * mx.exp(c[:, :, n])[..., None]) @ St + qk[:, :, n] @ v_new)
        last = c[:, :, n, -1]
        kd = k[:, :, n] * mx.exp(last[..., None] - c[:, :, n])[..., None]
        S = S * mx.exp(last)[..., None, None] + (kd.swapaxes(-1, -2) @ v_new).swapaxes(-1, -2)
    y = mx.stack(out, axis=2).reshape(B, H, N * CHUNK, Dv)[:, :, :T].transpose(0, 2, 1, 3)
    return y.astype(dtype), S


reference_update = gated_delta.gated_delta_update
ENGINE = {"train": "chunked"}


def update(q, k, v, a, b, A_log, dt_bias, state=None, mask=None, *, use_kernel=True, **kw):
    if use_kernel or ENGINE["train"] == "sequential":
        return reference_update(q, k, v, a, b, A_log, dt_bias, state, mask, use_kernel=use_kernel, **kw)
    if state is None:
        state = mx.zeros((q.shape[0], v.shape[2], v.shape[3], q.shape[3]), dtype=mx.float32)
    log_g = -mx.exp(A_log.astype(mx.float32)) * nn.softplus(a + dt_bias)
    return chunked_delta(q, k, v, log_g, mx.sigmoid(b), state)


qwen3_5.gated_delta_update = update


def made_up_pairs(n, seed=0):
    rng = random.Random(seed)
    clean = ["Can you send me the report by Friday?", "Let's move the standup to Thursday.",
             "I think we should spend 25% of the budget on marketing.", "Send it to Sarah.",
             "Remind me to call the dentist tomorrow at 9.", "The demo went well, but they want pricing first.",
             "We finish onboarding next week, then start on billing.", "Pick up groceries on the way home.",
             "Book a table for four at 7 on Saturday.", "The export bug only happens with large files.",
             "Ask Priya whether the contract is signed.", "I'll be about ten minutes late.",
             "Let's ship the beta on Monday and gather feedback.", "Please review the pull request before lunch.",
             "The new design looks great on mobile.", "Can we push the launch to next month?"]
    fillers = ["um", "uh", "like", "you know", "so"]
    out = []
    for i in range(n):
        target = rng.choice(clean)
        words = "".join(ch for ch in target.lower() if ch.isalnum() or ch in " '%").split()
        for _ in range(rng.randint(1, 3)):
            words.insert(rng.randint(0, len(words)), rng.choice(fillers))
        out.append((" ".join(words), target))
    return out


def encode(tok, pairs):
    rows = []
    for text, target in pairs:
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False)
        answer = tok.encode(target + "<|im_end|>", add_special_tokens=False)
        rows.append((prompt + answer, len(prompt)))
    return rows


def batches(rows, size, P=0):
    """Right-padded batches of similar length; `pick` indexes the positions whose next token is answer text.
    With P > 0 the first P tokens (the prompt every row shares) are cut off: ids holds the rest."""
    rows = sorted(rows, key=lambda r: len(r[0]))
    out = []
    for i in range(0, len(rows), size):
        group = rows[i: i + size]
        T = max(len(ids) for ids, _ in group) - 1 - P
        ids = np.zeros((len(group), T + 1 + P), np.int32)
        pick, labels = [], []
        for b, (seq, start) in enumerate(group):
            ids[b, : len(seq)] = seq
            for t in range(start - 1, len(seq) - 1):
                pick.append(b * T + t - P)
                labels.append(seq[t + 1])
        out.append((mx.array(ids[:, P:-1]), mx.array(pick), mx.array(labels), np.arange(i, i + len(group))))
    return out


def run_layers(lm, h, start):
    mask = "causal" if h.shape[1] > 1 else None
    for layer in lm.model.layers[start:]:
        h = layer(h, mask=None if layer.is_linear else mask)
    return h


def loss_fn(model, ids, pick, labels, start, cached, head_on_answer):
    lm = model.language_model
    h = cached if cached is not None else lm.model.embed_tokens(ids)
    h = lm.model.norm(run_layers(lm, h, start))
    B, T, D = h.shape
    if head_on_answer:  # the 248k-word head only where there is a label
        logits = lm.model.embed_tokens.as_linear(h.reshape(B * T, D)[pick])
        return nn.losses.cross_entropy(logits.astype(mx.float32), labels).mean()
    logits = lm.model.embed_tokens.as_linear(h).reshape(B * T, -1)[pick]
    return nn.losses.cross_entropy(logits.astype(mx.float32), labels).mean()


def shared_prefix_loss(model, ids, pick, labels, prefix):
    """Runs the shared prompt once, copies its attention keys/values and recurrent state to every row, then runs
    only each row's own tokens. Same loss and gradients as running every row in full."""
    lm = model.language_model
    cache = lm.make_cache()
    lm.model(prefix, cache=cache)
    B = ids.shape[0]
    for c in cache:
        if hasattr(c, "keys"):
            c.keys, c.values = mx.repeat(c.keys, B, 0), mx.repeat(c.values, B, 0)
        else:
            c[0], c[1] = mx.repeat(c[0], B, 0), mx.repeat(c[1], B, 0)
    h = lm.model(ids, cache=cache)
    D = h.shape[-1]
    logits = lm.model.embed_tokens.as_linear(h.reshape(-1, D)[pick])
    return nn.losses.cross_entropy(logits.astype(mx.float32), labels).mean()


def common_prefix(rows):
    first = rows[0][0]
    return min(next((i for i, (x, y) in enumerate(zip(first, ids)) if x != y), len(ids)) for ids, _ in rows)


def trial(name, rows, layers, batch, engine="chunked", cache_lower=False, head_on_answer=True, epochs=3, steps=None, share_prompt=False):
    ENGINE["train"] = engine
    mx.set_cache_limit(512 * 1024**2)  # uncapped, batched runs slow down 1.5-2x after the first epoch
    model, tok = load(MODEL)
    model.freeze()
    linear_to_lora_layers(model, layers, {"rank": 16, "scale": 10.0, "dropout": 0.0})
    model.train()
    start = 24 - layers if cache_lower else 0
    P = common_prefix(rows) if share_prompt else 0
    data = batches(rows, batch, P)
    prefix = mx.array([rows[0][0][:P]])
    if steps:
        data = data[:steps]
    cached = [None] * len(data)
    opt = optim.Adam(learning_rate=2e-5)  # the app's 1e-3, and 1e-4, diverge with adapters in every layer
    grad = nn.value_and_grad(model, shared_prefix_loss if share_prompt else loss_fn)
    mx.reset_peak_memory()
    times, losses = [], []
    for epoch in range(epochs):
        t0 = time.time()
        total = 0.0
        for i, (ids, pick, labels, _) in enumerate(data):
            if cache_lower and cached[i] is None:  # frozen layers below the adapters: their output never changes
                model.eval()
                cached[i] = mx.stop_gradient(run_layers_until(model.language_model, ids, start))
                mx.eval(cached[i])
                model.train()
            if share_prompt:
                loss, g = grad(model, ids, pick, labels, prefix)
            else:
                loss, g = grad(model, ids, pick, labels, start, cached[i], head_on_answer)
            opt.update(model, g)
            mx.eval(model.trainable_parameters(), opt.state, loss)
            total += loss.item()
        times.append(time.time() - t0)
        losses.append(total / len(data))
    n = sum(len(d[3]) for d in data)
    trainable = sum(v.size for _, v in tree_flatten(model.trainable_parameters()))
    print(f"{name}: epoch 1 {times[0]:.1f} s, later epochs {np.median(times[1:]):.1f} s for {n} pairs "
          f"({np.median(times[1:]) / n * 1000:.0f} ms/pair), loss {losses[0]:.3f} -> {losses[-1]:.3f}, "
          f"peak {mx.get_peak_memory() / 1e9:.1f} GB, {trainable / 1e6:.1f}M trainable", flush=True)
    return model


def run_layers_until(lm, ids, stop):
    h = lm.model.embed_tokens(ids)
    mask = "causal"
    for layer in lm.model.layers[:stop]:
        h = layer(h, mask=None if layer.is_linear else mask)
    return h


def parity():
    """Chunked vs MLX's sequential reference: the same loss and gradients with LoRA in every layer."""
    model, tok = load(MODEL)
    model.freeze()
    linear_to_lora_layers(model, 24, {"rank": 16, "scale": 10.0, "dropout": 0.0})
    # B starts at zero, so the model is unchanged, but B's gradient still flows back through every layer
    model.train()
    ids, pick, labels, _ = batches(encode(tok, made_up_pairs(2, seed=1)), 2)[0]
    grad = nn.value_and_grad(model, loss_fn)
    res = {}
    for engine in ("sequential", "chunked"):
        ENGINE["train"] = engine
        h = model.language_model.model.embed_tokens(ids).astype(mx.float32)  # fp32 so bf16 rounding doesn't hide errors
        loss, g = grad(model, ids, pick, labels, 0, h, True)
        mx.eval(loss, g)
        res[engine] = (loss.item(), dict(tree_flatten(g)))
    (l0, g0), (l1, g1) = res["sequential"], res["chunked"]
    worst = max(float(mx.abs(g0[k] - g1[k]).max() / (mx.abs(g0[k]).max() + 1e-12)) for k in g0)
    print(f"parity: loss {l0:.5f} sequential vs {l1:.5f} chunked, worst gradient difference {worst:.2%} of its max")
    assert abs(l0 - l1) < 1e-3 and worst < 0.01, "chunked delta rule disagrees with the reference"
    rows = encode(tok, made_up_pairs(4, seed=2))
    full = batches(rows, 4)[0]
    P = common_prefix(rows)
    cut = batches(rows, 4, P)[0]
    a = loss_fn(model, *full[:3], 0, None, True).item()
    b = shared_prefix_loss(model, *cut[:3], mx.array([rows[0][0][:P]])).item()
    print(f"shared prompt ({P} tokens): loss {a:.4f} in full vs {b:.4f} shared")
    assert abs(a - b) < 2e-2, "sharing the prompt changes the loss"


TRIALS = [
    ("top 1 layer, batch 1 (today's app)", dict(layers=1, batch=1)),
    ("all 24, sequential reference, batch 1, 8 pairs", dict(layers=24, batch=1, engine="sequential", steps=8)),
    ("all 24, chunked, batch 1", dict(layers=24, batch=1)),
    ("all 24, chunked, batch 4", dict(layers=24, batch=4)),
    ("all 24, chunked, batch 4, head on every token", dict(layers=24, batch=4, head_on_answer=False)),
    ("top 12, chunked, batch 4, lower half cached", dict(layers=12, batch=4, cache_lower=True)),
    ("top 12, chunked, batch 1, lower half cached", dict(layers=12, batch=1, cache_lower=True)),
    ("all 24, chunked, batch 4, prompt shared", dict(layers=24, batch=4, share_prompt=True)),
    ("all 24, chunked, batch 8, prompt shared", dict(layers=24, batch=8, share_prompt=True)),
    ("all 24, chunked, batch 8, prompt shared, 12 epochs", dict(layers=24, batch=8, share_prompt=True, epochs=12)),
]

if __name__ == "__main__":
    # one setup per process, so memory from one doesn't slow the next
    if len(sys.argv) == 1:
        parity()
    else:
        _, tok = load(MODEL)
        name, kw = TRIALS[int(sys.argv[1])]
        trial(name, encode(tok, made_up_pairs(64)), **kw)
