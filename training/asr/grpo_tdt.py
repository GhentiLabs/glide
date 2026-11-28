"""GRPO for NeMo TDT models (Parakeet). NeMo has no RL for transducers, so this is ours.

Each clip gets G sampled transcripts. A sample is one path through the token-and-duration
lattice: at frame t the joint gives a token distribution and a duration distribution; we
sample both, advance the prediction network on non-blank tokens, and jump d frames. The
policy is the path distribution, so log p(path) = sum of the sampled token and duration
log-probs, recomputed with gradients only at the visited (t, u) points.

Settings follow Fish Audio Drama 3: mean-centred advantages (Dr. GRPO), no KL, groups
with reward spread under 0.05 dropped, one optimizer step per rollout batch (so the PPO
ratio is 1 and needs no clipping), large batches, small constant learning rate.

Some clips get a second speaker mixed in quietly while the reward still uses the main speaker's text,
so the model learns to ignore another voice in the room.

    python training/asr/grpo_tdt.py --data /workspace/asr/hard-1.jsonl
    python training/asr/grpo_tdt.py --selftest
"""

import argparse
import random
import re
import time

import torch

MAX_SYMBOLS_PER_FRAME = 10


def norm_words(t: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", t.lower())


def wer(hyp: str, ref: str) -> float:
    from rapidfuzz.distance import Levenshtein  # word-level edit distance in C; mine_hard scores 200k clips with it

    h, r = norm_words(hyp), norm_words(ref)
    return Levenshtein.distance(h, r) / max(len(r), 1)


def reward(hyp: str, ref: str) -> float:
    if len(norm_words(hyp)) > 2 * len(norm_words(ref)) + 5:
        return -1.0  # runaway output; Drama 3 bounds length by budget, we also punish it
    return 1.0 - min(wer(hyp, ref), 1.0)


def encode(model, audio, audio_len):
    feats, feat_len = model.preprocessor(input_signal=audio, length=audio_len)
    enc, enc_len = model.encoder(audio_signal=feats, length=feat_len)
    return model.joint.project_encoder(enc.transpose(1, 2)), enc_len  # [B, T, H]


def gumbel_argmax(logits):
    """A sample from softmax(logits): argmax of logits plus Gumbel noise. No sync, no multinomial."""
    return (logits - torch.empty_like(logits).exponential_().log()).argmax(-1)


def lstm_step(model, tok, state):
    """One prediction-network step written out (embedding, then each LSTM layer, eval mode), so a CUDA graph can
    capture it. Blank embeds to zeros, as at the start of a sequence."""
    lstm = model.decoder.prediction["dec_rnn"].lstm
    x, (h, c) = model.decoder.prediction["embed"](tok), state
    hs, cs = [], []
    for k in range(lstm.num_layers):
        gates = x @ getattr(lstm, f"weight_ih_l{k}").T + getattr(lstm, f"bias_ih_l{k}") \
            + h[k] @ getattr(lstm, f"weight_hh_l{k}").T + getattr(lstm, f"bias_hh_l{k}")
        i, f, g, o = gates.chunk(4, -1)
        ck = f.sigmoid() * c[k] + i.sigmoid() * g.tanh()
        x = o.sigmoid() * ck.tanh()
        hs.append(x)
        cs.append(ck)
    return x, (torch.stack(hs), torch.stack(cs))


class Sampler:
    """Samples one TDT path per row of f with every tensor on the device and a fixed shape, so the loop never waits
    on the GPU; on CUDA, `check_every` steps are captured once as a CUDA graph and replayed.
    After run(): rec[r, :n[r]] holds (t, u, token, duration index) per step, toks[r, :u[r]] the emitted tokens."""

    def __init__(self, model, f, f_len, temperature=1.0, check_every=32):
        N, T, H = f.shape
        dev, self.model, self.check_every = f.device, model, check_every
        self.f, self.f_len, self.temperature = f, f_len, temperature
        self.blank = model.decoder.blank_idx
        self.durs = torch.tensor(model.cfg.model_defaults.tdt_durations, device=dev)
        self.max_steps = int(f_len.max()) * (MAX_SYMBOLS_PER_FRAME + 1)  # every step emits or moves a frame
        lstm = model.decoder.prediction["dec_rnn"].lstm
        zeros = torch.zeros(lstm.num_layers, N, lstm.hidden_size, device=dev, dtype=f.dtype)
        self.state = (zeros, zeros.clone())
        self.g = model.joint.project_prednet(lstm_step(model, torch.full((N,), self.blank, device=dev), self.state)[0])
        z = lambda: torch.zeros(N, dtype=torch.long, device=dev)
        self.t, self.u, self.n, self.here = z(), z(), z(), z()
        # one spare slot: finished rows keep writing scratch at index n (or u), which can reach max_steps
        self.rec = torch.zeros(N, self.max_steps + 1, 4, dtype=torch.long, device=dev)
        self.toks = torch.full((N, self.max_steps + 1), self.blank, dtype=torch.long, device=dev)
        self.rows = torch.arange(N, device=dev)

    def step(self):
        m, n_dur = self.model, len(self.durs)
        active = self.t < self.f_len
        ft = self.f[self.rows, self.t.clamp(max=self.f.shape[1] - 1)]
        logits = m.joint.joint_after_projection(ft[:, None, :], self.g[:, None, :])[:, 0, 0].float() / self.temperature
        tok = gumbel_argmax(logits[:, :-n_dur])
        tok = torch.where(self.here >= MAX_SYMBOLS_PER_FRAME, self.blank, tok)  # a path cannot loop on one frame
        blank = tok == self.blank
        d = gumbel_argmax(logits[:, -n_dur:].masked_fill(blank[:, None] & (self.durs == 0), float("-inf")))
        self.rec[self.rows, self.n] = torch.stack([self.t, self.u, tok, d], 1)  # past n, slots are scratch
        self.toks[self.rows, self.u] = tok
        emit = active & ~blank
        g_new, s_new = lstm_step(m, tok, self.state)
        self.g.copy_(torch.where(emit[:, None], m.joint.project_prednet(g_new), self.g))
        for s, sn in zip(self.state, s_new):
            s.copy_(torch.where(emit[None, :, None], sn, s))
        step = self.durs[d]
        self.here.copy_(torch.where(active & (step == 0), self.here + 1, 0))
        self.t.add_(torch.where(active, step, 0))
        self.u.add_(emit.long())
        self.n.add_(active.long())

    def run(self):
        steps = lambda: [self.step() for _ in range(self.check_every)]
        if self.f.is_cuda:
            snapshot = [x.clone() for x in (self.g, *self.state, self.t, self.u, self.n, self.here)]
            side = torch.cuda.Stream()
            side.wait_stream(torch.cuda.current_stream())
            with torch.cuda.stream(side):
                steps()  # warm-up, as CUDA graph capture requires; undone below
            torch.cuda.current_stream().wait_stream(side)
            for x, x0 in zip((self.g, *self.state, self.t, self.u, self.n, self.here), snapshot):
                x.copy_(x0)
            graph = torch.cuda.CUDAGraph()
            with torch.cuda.graph(graph):
                steps()
            steps = graph.replay
        for _ in range(0, self.max_steps, self.check_every):
            steps()
            if not (self.t < self.f_len).any():
                break
        return self


@torch.no_grad()
def sample(model, f, f_len, temperature=1.0):
    return Sampler(model, f, f_len, temperature).run()


def path_logp(model, f, s, rows, chunk=32_768):
    """Differentiable log p(path) for the given rows of sampler s, averaged per step (GRPO length normalisation).
    All visited points go through the joint in one batch, in checkpointed chunks to bound memory."""
    blank, n_dur = model.decoder.blank_idx, len(s.durs)
    u, n = s.u[rows], s.n[rows]
    U = max(int(u.max()), 1)
    with torch.backends.cudnn.flags(enabled=False):  # cuDNN's LSTM backward refuses eval mode; ~50 steps, so cheap
        g, _, _ = model.decoder(targets=s.toks[rows, :U], target_length=u)
    g = model.joint.project_prednet(g.transpose(1, 2))  # [R, U+1, H], g[:, k] = state after k tokens
    b, k = (torch.arange(s.rec.shape[1], device=f.device) < n[:, None]).nonzero(as_tuple=True)
    pt = s.rec[rows[b], k]  # [P, 4]

    def lp_chunk(fp, gp, tok, d):
        logits = model.joint.joint_after_projection(fp[:, None], gp[:, None])[:, 0, 0].float()
        tl, dl = logits[:, :-n_dur], logits[:, -n_dur:]
        dl = dl.masked_fill((tok == blank)[:, None] & (s.durs == 0), float("-inf"))
        return tl.gather(1, tok[:, None])[:, 0] - tl.logsumexp(-1) + dl.gather(1, d[:, None])[:, 0] - dl.logsumexp(-1)

    lp = torch.cat([
        torch.utils.checkpoint.checkpoint(lp_chunk, f[b[i:i + chunk], pt[i:i + chunk, 0]], g[b[i:i + chunk], pt[i:i + chunk, 1]],
                                          pt[i:i + chunk, 2], pt[i:i + chunk, 3], use_reentrant=False)
        for i in range(0, len(pt), chunk)])
    return torch.zeros(len(rows), device=f.device, dtype=lp.dtype).index_add(0, b, lp) / n


def grpo_step(model, opt, audio, audio_len, refs, G=8, min_std=0.05):
    """One on-policy GRPO update. Returns stats for logging.
    Eval mode throughout (no dropout): samples come from the model as it runs at inference, and the log-probs being
    trained are those of the same policy. With dropout on, samples were far worse than greedy decoding."""
    model.eval()
    f, f_len = encode(model, audio, audio_len)  # once per clip; the group shares it
    f, f_len = f.repeat_interleave(G, 0), f_len.repeat_interleave(G, 0)
    s = sample(model, f.detach(), f_len)
    toks, u = s.toks.cpu(), s.u.cpu()
    hyps = [model.tokenizer.ids_to_text(toks[i, :u[i]].tolist()) for i in range(len(u))]
    r = torch.tensor([reward(h, refs[i // G]) for i, h in enumerate(hyps)], device=f.device).view(-1, G)
    keep = r.std(1) >= min_std  # Drama 3: groups that cannot tell samples apart carry no signal
    adv = (r - r.mean(1, keepdim=True)).flatten()
    rows = keep.repeat_interleave(G).nonzero().squeeze(1)
    stats = {"reward": r.mean().item(), "wer_mean": 1 - r.clamp(min=0).mean().item(), "groups_kept": keep.float().mean().item()}
    if len(rows):
        loss = -(adv[rows] * path_logp(model, f[rows], s, rows)).mean()
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        stats["loss"] = loss.item()
    return stats, hyps


def mix_voice(x: torch.Tensor, other: torch.Tensor, snr_db: float, start: int) -> torch.Tensor:
    """Overlay `other` from sample `start` on, snr_db quieter than x over the stretch it covers."""
    seg = other[: len(x) - start]
    gain = x.pow(2).mean().sqrt() / seg.pow(2).mean().sqrt().clamp_min(1e-8) * 10 ** (-snr_db / 20)
    out = x.clone()
    out[start:start + len(seg)] += gain * seg
    return out


def load_batches(manifest: str, batch_size: int, seed: int, mix: float = 0.0, max_sec: float = 20.0):
    import json

    import soundfile as sf

    read = lambda r: torch.from_numpy(sf.read(r["audio_filepath"], dtype="float32")[0])
    # a batch pads to its longest clip and attention grows with its square: one 40 s clip ran 32 others out of memory
    rows = [r for r in map(json.loads, open(manifest)) if r["duration"] <= max_sec]
    rng = random.Random(seed)
    rng.shuffle(rows)
    for i in range(0, len(rows) - batch_size + 1, batch_size):
        batch = []
        for r in rows[i:i + batch_size]:
            x = read(r)
            if rng.random() < mix:  # another speaker 5-20 dB quieter, starting in the first half
                x = mix_voice(x, read(rng.choice(rows)), rng.uniform(5, 20), rng.randrange(max(1, len(x) // 2)))
            batch.append((x, r["text"]))
        audio = torch.nn.utils.rnn.pad_sequence([a for a, _ in batch], batch_first=True)
        yield audio, torch.tensor([len(a) for a, _ in batch]), [t for _, t in batch]


def prefetch(it, depth=2):
    """Run a generator `depth` items ahead in a thread, so decoding the next batch overlaps the GPU step."""
    import queue
    import threading

    q, end = queue.Queue(depth), object()

    def fill():
        try:
            for x in it:
                q.put(x)
            q.put(end)
        except BaseException as e:  # hand the error to the training loop instead of hanging it
            q.put(e)

    threading.Thread(target=fill, daemon=True).start()
    while (x := q.get()) is not end:
        if isinstance(x, BaseException):
            raise x
        yield x


def main():
    import fluid_speech

    p = argparse.ArgumentParser()
    p.add_argument("--model", default="FluidVoice-Labs/fluid-speech-pro", help="Hub id or .nemo")
    p.add_argument("--data", required=True, help="NeMo manifest of hard clips from mine_hard.py")
    p.add_argument("--out", default="parakeet-grpo.nemo")
    p.add_argument("--clips_per_step", type=int, default=32)  # x G rollouts per step; 32 clips peak at ~33 GB
    p.add_argument("--G", type=int, default=8)
    p.add_argument("--lr", type=float, default=1e-6)
    p.add_argument("--steps", type=int, default=300)
    p.add_argument("--mix", type=float, default=0.3, help="share of clips with a second voice mixed in")
    p.add_argument("--freeze_encoder", action="store_true", help="train only the 9M-param decoder and joint")
    a = p.parse_args()

    model = fluid_speech.load(a.model)
    model = model.cuda() if torch.cuda.is_available() else model
    if a.freeze_encoder:
        model.encoder.freeze()
    opt = torch.optim.AdamW([q for q in model.parameters() if q.requires_grad], lr=a.lr, weight_decay=0.0)
    dev = next(model.parameters()).device
    t0 = time.time()
    for step, (audio, alen, refs) in enumerate(prefetch(load_batches(a.data, a.clips_per_step, seed=0, mix=a.mix))):
        if step >= a.steps:
            break
        with torch.autocast(dev.type, dtype=torch.bfloat16, enabled=dev.type == "cuda"):
            stats, _ = grpo_step(model, opt, audio.to(dev), alen.to(dev), refs, G=a.G)
        print(step, {k: round(v, 4) for k, v in stats.items()}, f"{time.time() - t0:.0f}s", flush=True)
    model.save_to(a.out)


def selftest():
    """CPU check on two synthetic clips: sampling terminates, log-probs are finite and backprop works."""
    import fluid_speech

    assert wer("Hello, world!", "hello world") == 0.0 and wer("the cat sat", "the cat sat down") == 0.25
    assert list(prefetch(iter(range(5)))) == list(range(5))
    assert reward("a " * 50, "hello world") == -1.0
    x, o = torch.randn(16000), torch.randn(4000) * 3
    m = mix_voice(x, o, 10.0, 8000)
    assert torch.equal(m[:8000], x[:8000]) and torch.equal(m[12000:], x[12000:])
    snr = 10 * torch.log10(x.pow(2).mean() / (m - x)[8000:12000].pow(2).mean())
    assert abs(snr - 10.0) < 0.5, snr
    torch.manual_seed(0)
    model = fluid_speech.load("FluidVoice-Labs/fluid-speech-pro", map_location="cpu")
    model.encoder.freeze()
    opt = torch.optim.AdamW([q for q in model.parameters() if q.requires_grad], lr=1e-6)
    audio = torch.randn(2, 16000 * 2) * 0.01
    stats, hyps = grpo_step(model, opt, audio, torch.tensor([32000, 24000]), ["hello world", "test"], G=4, min_std=0.0)
    assert len(hyps) == 8 and "loss" in stats and stats["loss"] == stats["loss"], stats  # not NaN
    model.eval()
    tok = torch.tensor([5, model.decoder.blank_idx, 17])
    g_ref, s_ref = model.decoder.predict(tok[:, None], None, add_sos=False)
    g, st = lstm_step(model, tok, tuple(torch.zeros(2, 3, 640) for _ in range(2)))
    assert torch.allclose(g, g_ref[:, 0], atol=1e-5) and all(torch.allclose(a, b, atol=1e-5) for a, b in zip(st, s_ref))
    f, f_len = encode(model, audio[:1], torch.tensor([32000]))
    s = sample(model, f, f_len)
    path, n, u = s.rec[0, : s.n[0]], s.n[0].item(), s.u[0].item()
    lp = path_logp(model, f, s, torch.tensor([0]))
    assert torch.isfinite(lp).all() and lp.item() <= 0, lp
    assert (path[1:, 0] >= path[:-1, 0]).all() and path[-1, 0] < f_len[0] <= path[-1, 0] + s.durs[path[-1, 3]]
    assert (path[:, 2] != model.decoder.blank_idx).sum() == u and (path[:, 1] == torch.cummax(path[:, 1], 0)[0]).all()
    print("selftest ok", stats)


if __name__ == "__main__":
    import sys

    selftest() if "--selftest" in sys.argv else main()
