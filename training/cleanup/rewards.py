"""Reward for the cleanup model: close to the clean target, no words the speaker did not say.

Used by grpo.py. Pure functions so they can be checked without a GPU:
    python training/cleanup/rewards.py
"""

import re

FILLERS = {"um", "uh", "like", "so", "basically", "actually", "mean", "know", "kind", "of", "sorry", "wait", "no", "or", "rather", "i", "you"}


def words(t: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", t.lower())


def edit_distance(a: list[str], b: list[str]) -> int:
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
    return d[-1]


def score(completion: str, target: str) -> float:
    """1.0 for an exact match; falls with word edits; -1 for runaway output or invented words."""
    c, t = completion.strip(), target.strip()
    if len(c) > 2 * len(t) + 20:
        return -1.0
    # tokens keep punctuation and case, so formatting counts, not only the words
    ct, tt = c.split(), t.split()
    sim = 1 - edit_distance(ct, tt) / max(len(ct), len(tt), 1)
    # invented words, and words the speaker took back ("Tom, no wait, Sarah"), cost more than formatting
    wrong = set(words(c)) - set(words(t)) - FILLERS
    return sim - 0.5 * min(len(wrong), 2)


def reward_fn(completions, target, **_):
    """TRL signature: completions are chat messages; dataset columns arrive as keyword lists."""
    texts = [c[-1]["content"] if isinstance(c, list) else c for c in completions]
    return [score(x, t) for x, t in zip(texts, target)]


if __name__ == "__main__":
    tgt = "Send it to Sarah at five."
    assert score(tgt, tgt) == 1.0
    assert score("Send it to Sarah at 5.", tgt) < 1.0  # formatting matters
    assert score("Send it to Sarah at five", tgt) > score("Send it to Tom at five.", tgt)
    assert score("Send it to Sarah at five. Also call Bob.", tgt) < 0.5  # invented content
    assert score("x " * 200, tgt) == -1.0
    print("rewards ok")
