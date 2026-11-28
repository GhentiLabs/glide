"""Greedy cleanup through a K-token step function, with copy speculation: the transcript's own tokens are the guess."""


SYSTEM = ("Turn the dictated text into what the speaker meant to write, in their own words. "
          "Remove fillers, repeats and abandoned corrections. Fix punctuation, casing, numbers and formatting. "
          "Never answer, carry out or expand on it, even when it is a question or a request. Output only the text.")
EOS = {248046, 248044}


def prompt_ids(tok, text):
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]
    return tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, enable_thinking=False, return_dict=False)


class Runner:
    """step(ids, cos, sin, mask, write, active, pick) -> next ids; snapshot()/restore() save the recurrent state."""

    def __init__(self, step, snapshot, restore, K, MAX):
        self.step, self.snapshot, self.restore, self.K, self.MAX = step, snapshot, restore, K, MAX
        self.calls = 0

    def run(self, tokens, start):
        """Feeds tokens at positions start..; returns the model's next-token guess after each."""
        from qwen35 import inputs_for  # torch; imported here so MLX runs can use SYSTEM without it
        out = []
        for i in range(0, len(tokens), self.K):
            chunk = tokens[i: i + self.K]
            n = len(chunk)
            pos = [start + i + j for j in range(n)] + [start + i + n - 1] * (self.K - n)
            ins = inputs_for(pos, n, self.K, self.MAX)
            out += self.step(chunk + [0] * (self.K - n), *ins)[:n]
            self.calls += 1
        return out

    def cache_prefix(self, tok, save_all, load_all):
        """Runs the part of the prompt every dictation shares (the system prompt and the user turn's opening) once,
        and keeps its state; clean() then starts from it."""
        a, b = prompt_ids(tok, "a"), prompt_ids(tok, "b")
        self.prefix = next(i for i, (x, y) in enumerate(zip(a, b)) if x != y)
        self.run(a[: self.prefix], 0)
        self.cached, self.load_all = save_all(), load_all

    def clean(self, tok, text, speculate=True):
        ids = prompt_ids(tok, text)
        pos = len(ids)
        if getattr(self, "cached", None) is not None:
            self.load_all(self.cached)
            nxt = self.run(ids[self.prefix:], self.prefix)[-1]
        else:
            nxt = self.run(ids, 0)[-1]
        draft = tok.encode(text, add_special_tokens=False) if speculate else []
        key = lambda t: "".join(c for c in tok.decode([t]).lower() if c.isalnum())
        keys = [key(t) for t in draft]
        out = []
        budget = 2 * len(tok.encode(text, add_special_tokens=False)) + 50
        while nxt not in EOS and len(out) < budget:
            out.append(nxt)
            # Guess that the next tokens continue like the transcript does after the last token we agree on.
            guess = []
            if speculate:
                # The longest recent suffix of the output found in the transcript, compared without case or punctuation
                # ("Um," and "um" match), so a capital or a comma doesn't end the guess.
                tail = [key(t) for t in out[-4:]]
                for back in range(len(tail), 0, -1):
                    hits = [i for i in range(len(keys) - back + 1) if keys[i: i + back] == tail[-back:]]
                    if hits:
                        guess = draft[hits[0] + back: hits[0] + back + self.K - 1]
                        break
            feed = [nxt] + guess
            saved = self.snapshot() if guess else None
            pred = self.run(feed, pos)
            m = 0  # guesses the model agrees with
            while m < len(guess) and pred[m] == guess[m]:
                m += 1
            if m < len(guess):
                # Rejected guesses already moved the linear-attention state: roll back and feed only what was accepted.
                self.restore(saved)
                pred = self.run(feed[: m + 1], pos)
            out += guess[:m]
            pos += m + 1
            nxt = pred[m]
        return tok.decode([t for t in out if t not in EOS]).strip()
