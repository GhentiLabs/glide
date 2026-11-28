"""Qwen3.5 text model rewritten for Core ML: fixed shapes, explicit state, LoRA slots in every projection.

One call takes K tokens. The caller (Swift, or the Python harness here) supplies what depends on positions:
  ids      int32 [1, K]   token ids
  cos/sin  fp16  [K, 64]  rotary angles for each token's position
  mask     fp16  [K, MAX] additive attention mask: 0 where a token may look, -1e4 elsewhere
  write    fp16  [MAX, K] one-hot: where each token's key and value go in the cache (zero column = inactive token)
  active   fp16  [K]      1 for real tokens, a prefix; padding tokens don't touch the linear-attention state
  pick     fp16  [3, 3+K] one-hot: the last 3 real conv inputs, the next conv state
State: attention keys and values for the 6 full-attention layers, conv and recurrent state for the 18 linear ones.
Output: the greedy next token after each input token.
"""

import json
import math
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from safetensors.torch import load_file

RANK = 8


class LoraLinear(nn.Module):
    """x·Wᵀ + (x·Aᵀ)·Bᵀ. B starts at zero, so the model is unchanged until an add-on is written into it."""

    def __init__(self, weight: torch.Tensor, rank: int = RANK):
        super().__init__()
        out_f, in_f = weight.shape
        self.weight = nn.Parameter(weight, requires_grad=False)
        self.lora_a = nn.Parameter(torch.randn(rank, in_f) / math.sqrt(in_f))
        self.lora_b = nn.Parameter(torch.zeros(out_f, rank))

    def forward(self, x):
        return F.linear(x, self.weight) + F.linear(F.linear(x, self.lora_a), self.lora_b)


def rms(x, w, eps=1e-6, centered=True):
    x = x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + eps)
    return x * (1 + w) if centered else x * w


class Qwen35(nn.Module):
    def __init__(self, model_dir: str | Path, K: int = 16, MAX: int = 1024):
        super().__init__()
        cfg = json.loads((Path(model_dir) / "config.json").read_text())
        c = cfg.get("text_config", cfg)
        sd = {k.removeprefix("model.language_model.").removeprefix("model."): v.float()
              for k, v in load_file(str(Path(model_dir) / "model.safetensors")).items()}
        self.K, self.MAX = K, MAX
        self.types = c["layer_types"]
        self.eps = c["rms_norm_eps"]
        self.heads, self.kv_heads, self.hd = c["num_attention_heads"], c["num_key_value_heads"], c["head_dim"]
        self.vh, self.kh = c["linear_num_value_heads"], c["linear_num_key_heads"]
        self.dk, self.dv = c["linear_key_head_dim"], c["linear_value_head_dim"]
        self.embed = nn.Parameter(sd["embed_tokens.weight"], requires_grad=False)
        self.norm = nn.Parameter(sd["norm.weight"], requires_grad=False)
        self.layers = nn.ModuleList()
        for i, t in enumerate(self.types):
            p = f"layers.{i}."
            L = nn.Module()
            L.ln1 = nn.Parameter(sd[p + "input_layernorm.weight"], requires_grad=False)
            L.ln2 = nn.Parameter(sd[p + "post_attention_layernorm.weight"], requires_grad=False)
            for n in ("gate_proj", "up_proj", "down_proj"):
                setattr(L, n, LoraLinear(sd[p + f"mlp.{n}.weight"]))
            if t == "full_attention":
                a = p + "self_attn."
                for n in ("q_proj", "k_proj", "v_proj", "o_proj"):
                    setattr(L, n, LoraLinear(sd[a + f"{n}.weight"]))
                L.q_norm = nn.Parameter(sd[a + "q_norm.weight"], requires_grad=False)
                L.k_norm = nn.Parameter(sd[a + "k_norm.weight"], requires_grad=False)
            else:
                a = p + "linear_attn."
                for n in ("in_proj_qkv", "in_proj_z", "out_proj"):
                    setattr(L, n, LoraLinear(sd[a + f"{n}.weight"]))
                L.in_proj_b = nn.Parameter(sd[a + "in_proj_b.weight"], requires_grad=False)
                L.in_proj_a = nn.Parameter(sd[a + "in_proj_a.weight"], requires_grad=False)
                L.conv = nn.Parameter(sd[a + "conv1d.weight"][:, 0, :], requires_grad=False)  # [C, 4]
                L.dt_bias = nn.Parameter(sd[a + "dt_bias"], requires_grad=False)
                L.A = nn.Parameter(-sd[a + "A_log"].exp(), requires_grad=False)
                L.gnorm = nn.Parameter(sd[a + "norm.weight"], requires_grad=False)
            self.layers.append(L)
        n_attn = self.types.count("full_attention")
        n_lin = len(self.types) - n_attn
        conv_dim = 2 * self.kh * self.dk + self.vh * self.dv
        tri = torch.ones(K, K)
        self.register_buffer("upper", tri.triu(), persistent=False)
        self.register_buffer("lower", tri.tril(), persistent=False)
        self.register_buffer("strict", tri.tril(-1), persistent=False)
        self.register_buffer("eye", torch.eye(K), persistent=False)
        # One state per layer: the Neural Engine compiler fails when two layers update slices of one state.
        for j in range(n_attn):
            self.register_buffer(f"k{j}", torch.zeros(self.kv_heads, MAX, self.hd))
            self.register_buffer(f"v{j}", torch.zeros(self.kv_heads, MAX, self.hd))
        for j in range(n_lin):
            self.register_buffer(f"conv{j}", torch.zeros(3, conv_dim))
            self.register_buffer(f"rec{j}", torch.zeros(self.vh, self.dk, self.dv))
        self.linear_states = [f"{n}{j}" for j in range(n_lin) for n in ("conv", "rec")]
        self.states = [f"{n}{j}" for j in range(n_attn) for n in ("k", "v")] + self.linear_states

    def attention(self, L, j, x, cos, sin, mask, write):
        K, hd = self.K, self.hd
        q, gate = L.q_proj(x).view(K, self.heads, 2 * hd).split(hd, dim=-1)
        q = rms(q, L.q_norm, self.eps).transpose(0, 1)                                  # [H, K, hd]
        k = rms(L.k_proj(x).view(K, self.kv_heads, hd), L.k_norm, self.eps).transpose(0, 1)
        v = L.v_proj(x).view(K, self.kv_heads, hd).transpose(0, 1)
        r = 64  # rotary dims: head_dim × partial_rotary_factor

        def rope(t):
            t1, t2, rest = t[..., : r // 2], t[..., r // 2: r], t[..., r:]
            return torch.cat([t1 * cos[:, : r // 2] - t2 * sin[:, : r // 2], t2 * cos[:, r // 2:] + t1 * sin[:, r // 2:], rest], -1)

        q, k = rope(q), rope(k)
        keep = 1 - write.sum(-1, keepdim=True)                                           # [MAX, 1]
        kc, vc = getattr(self, f"k{j}"), getattr(self, f"v{j}")
        kc[:] = kc * keep + write @ k
        vc[:] = vc * keep + write @ v
        rep = self.heads // self.kv_heads
        keys = kc.repeat_interleave(rep, 0)
        vals = vc.repeat_interleave(rep, 0)
        att = torch.softmax(q @ keys.transpose(1, 2) / math.sqrt(hd) + mask, dim=-1)
        out = (att @ vals).transpose(0, 1).reshape(K, -1) * torch.sigmoid(gate.reshape(K, -1))
        return L.o_proj(out)

    def linear_attention(self, L, j, x, active, pick):
        K = self.K
        qkv = L.in_proj_qkv(x)                                                           # [K, C]
        z = L.in_proj_z(x).view(K, self.vh, self.dv)
        beta = torch.sigmoid(x @ L.in_proj_b.T)                                          # [K, vh]
        g = L.A * F.softplus(x @ L.in_proj_a.T + L.dt_bias)                              # log-decay, [K, vh]
        cs = getattr(self, f"conv{j}")
        inp = torch.cat([cs, qkv], 0)                                    # [3+K, C]
        conv = sum(inp[i: i + K] * L.conv[:, i] for i in range(4))
        cs[:] = pick @ inp
        conv = F.silu(conv)
        kd = self.kh * self.dk
        q = conv[:, :kd].view(K, self.kh, self.dk)
        k = conv[:, kd: 2 * kd].view(K, self.kh, self.dk)
        v = conv[:, 2 * kd:].view(K, self.vh, self.dv)
        q = q * torch.rsqrt((q * q).sum(-1, keepdim=True) + 1e-6) / math.sqrt(self.dk)
        k = k * torch.rsqrt((k * k).sum(-1, keepdim=True) + 1e-6)
        if self.vh != self.kh:
            q, k = q.repeat_interleave(self.vh // self.kh, 1), k.repeat_interleave(self.vh // self.kh, 1)
        # Chunked gated delta rule for the K tokens at once (the UT form from the DeltaNet papers, as in transformers),
        # with the triangular inverse as a product of 4 matmuls since the strictly lower part is nilpotent.
        # Padding tokens get beta 0 and log-decay 0, so they leave the state alone.
        q, k, v = q.transpose(0, 1), k.transpose(0, 1), v.transpose(0, 1)                # [vh, K, d]
        beta = (beta * active[:, None]).T                                                # [vh, K]
        g = (g * active[:, None]).T
        cum = g @ self.upper                                                             # cumulative log-decay
        pair = torch.exp(torch.clamp(cum[:, :, None] - cum[:, None, :], max=0)) * self.lower
        kb, vb = k * beta[..., None], v * beta[..., None]
        Lw = (kb @ k.transpose(1, 2)) * pair * self.strict
        # Powers as X·(I+X) − X: the Neural Engine compiler fails on a matmul of a tensor with itself.
        A2 = self.eye + (Lw @ (self.eye + Lw) - Lw)
        A4 = self.eye + ((A2 - self.eye) @ A2 - (A2 - self.eye))
        A8 = self.eye + ((A4 - self.eye) @ A4 - (A4 - self.eye))
        inv = (self.eye - Lw) @ A2 @ A4 @ A8
        rec = getattr(self, f"rec{j}")
        S = rec                                                                          # [vh, dk, dv]
        new_v = inv @ vb - (inv @ (kb * torch.exp(cum)[..., None])) @ S
        attn = (q @ k.transpose(1, 2)) * pair
        out = (q * torch.exp(cum)[..., None]) @ S + attn @ new_v                         # [vh, K, dv]
        last = cum[:, -1:]
        rec[:] = S * torch.exp(last)[..., None] + (k * torch.exp(last - cum)[..., None]).transpose(1, 2) @ new_v
        outs = out.transpose(0, 1)
        core = outs                                                                      # [K, vh, dv]
        core = rms(core, L.gnorm, self.eps, centered=False) * F.silu(z)
        return L.out_proj(core.reshape(K, -1))

    def forward(self, ids, cos, sin, mask, write, active, pick):
        h = self.body(self.embed[ids[0]], cos, sin, mask, write, active, pick)
        logits = F.linear(h, self.embed)  # [vocab, D] layout, so 8-bit scales go per token
        return torch.argmax(logits, -1).to(torch.int32).unsqueeze(0)                    # [1, K]

    def body(self, x, cos, sin, mask, write, active, pick, start=0, stop=None):
        """Embedded tokens [K, D] through layers start..stop; final-normed after the last layer. Runs on the Neural
        Engine, whose tensor limits the 248k-row embedding and head exceed, in pieces of at most 12 layers."""
        stop = len(self.layers) if stop is None else stop
        ja, jl = self.types[:start].count("full_attention"), self.types[:start].count("linear_attention")
        for L, t in list(zip(self.layers, self.types))[start:stop]:
            h = rms(x, L.ln1, self.eps)
            if t == "full_attention":
                x = x + self.attention(L, ja, h, cos, sin, mask, write)
                ja += 1
            else:
                x = x + self.linear_attention(L, jl, h, active, pick)
                jl += 1
            h = rms(x, L.ln2, self.eps)
            x = x + L.down_proj(F.silu(L.gate_proj(h)) * L.up_proj(h))
        return rms(x, self.norm, self.eps) if stop == len(self.layers) else x

    def states_in(self, start, stop):
        """The state names layers start..stop use."""
        ja, jl = self.types[:start].count("full_attention"), self.types[:start].count("linear_attention")
        na, nl = self.types[start:stop].count("full_attention"), self.types[start:stop].count("linear_attention")
        return ([f"{n}{j}" for j in range(ja, ja + na) for n in ("k", "v")]
                + [f"{n}{j}" for j in range(jl, jl + nl) for n in ("conv", "rec")])


def inputs_for(positions: list[int], active_n: int, K: int, MAX: int, rope_dim: int = 64, theta: float = 1e7):
    """Position-dependent inputs for one call; positions has K entries, the first active_n are real."""
    inv = 1.0 / theta ** (torch.arange(0, rope_dim, 2, dtype=torch.float64) / rope_dim)
    pos = torch.tensor(positions, dtype=torch.float64)
    f = pos[:, None] * inv[None]
    cos, sin = torch.cat([f.cos()] * 2, -1).float(), torch.cat([f.sin()] * 2, -1).float()
    mask = torch.full((K, MAX), -1e4)
    write = torch.zeros(MAX, K)
    for i in range(active_n):
        write[positions[i], i] = 1
    for i in range(K):
        upto = positions[min(i, active_n - 1)] if active_n else 0
        mask[i, : upto + 1] = 0
    active = torch.tensor([1.0] * active_n + [0.0] * (K - active_n))
    pick = torch.zeros(3, 3 + K)
    for r in range(3):
        pick[r, active_n + r] = 1
    return cos, sin, mask, write, active, pick
