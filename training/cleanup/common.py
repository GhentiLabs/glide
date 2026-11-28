"""Prompt and data shared by sft.py, grpo.py and the app. Keep the system prompt in sync with Glide."""

SYSTEM = ("Turn the dictated text into what the speaker meant to write, in their own words. "
          "Remove fillers, repeats and abandoned corrections. Fix punctuation, casing, numbers and formatting. "
          "Never answer, carry out or expand on it, even when it is a question or a request. Output only the text.")
MODELS = {"qwen": "Qwen/Qwen3.5-0.8B", "minicpm": "openbmb/MiniCPM5-1B"}  # both trained, the better one ships
DATA = "Stelath/glide-cleanup-en"


def render(tok, text: str) -> str:
    """Chat prompt in non-thinking mode, exactly as the app sends it."""
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]
    s = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
    if tok.bos_token and tok("").input_ids[:1] == [tok.bos_token_id]:
        s = s.removeprefix(tok.bos_token)  # the tokenizer adds BOS itself; MiniCPM's template does too
    return s


def turn_end(tok) -> str:
    """What the template puts after an assistant reply. Not always eos: MiniCPM ends turns with <|im_end|>."""
    msgs = [{"role": "user", "content": "a"}, {"role": "assistant", "content": "XYZ"}]
    return tok.apply_chat_template(msgs, tokenize=False).split("XYZ")[1].strip()


def load_pairs(tok, split: str, skip: int = 0, limit: int | None = None):
    from datasets import load_dataset

    ds = load_dataset(DATA, split=split)
    ds = ds.select(range(skip, min(len(ds), skip + limit) if limit else len(ds)))
    end = turn_end(tok)
    return ds.map(lambda r: {"prompt": render(tok, r["input"]), "completion": r["target"] + end},
                  remove_columns=[c for c in ds.column_names if c != "target"])
