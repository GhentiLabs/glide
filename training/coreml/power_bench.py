"""Energy per cleanup: loads one engine, then cleans made-up sentences for SECONDS while powermetrics samples
CPU, GPU and ANE power. Needs cached sudo (power.sh runs `sudo -v` first).

  python power_bench.py idle|ane|mlx SECONDS
  python power_bench.py train 0      (times the nightly LoRA setup in train_probe.py instead)
"""

import os
import re
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.expanduser("~/glide-data")
SENTENCES = [
    "um so can you send me the report by friday",
    "what's the capital of france",
    "Could we move uh the standup to Thursday?",
    "I think we should use twenty five percent of the budget for marketing",
    "send it to Tom no wait Sarah",
    "okay so the plan for next week is we finish the onboarding flow then uh we start on the billing page and if we have time we fix the export bug",
    "remind me to call the dentist tomorrow at nine and also pick up groceries on the way home",
    "the meeting went well I think they liked the demo but they want to see pricing before they commit",
]


def ane_engine():
    import numpy as np
    import coremltools as ct
    from transformers import AutoTokenizer
    sys.path.insert(0, HERE)
    from harness import Runner

    tok = AutoTokenizer.from_pretrained(f"{DATA}/models/glide-cleanup-sft")
    P, K, MAX = f"{DATA}/coreml", 16, 512
    embed = np.load(f"{P}/p8-embed.npy")
    bodies = [ct.models.CompiledMLModel(f"{P}/compiled/p8-body{i}.mlmodelc", compute_units=ct.ComputeUnit.CPU_AND_NE)
              for i in (0, 1)]
    head = ct.models.CompiledMLModel(f"{P}/compiled/p16-head.mlmodelc", compute_units=ct.ComputeUnit.CPU_AND_GPU)
    lin = [[f"{n}{j}" for j in range(0, 9) for n in ("conv", "rec")], [f"{n}{j}" for j in range(9, 18) for n in ("conv", "rec")]]
    every = [[f"{n}{j}" for j in range(0, 3) for n in ("k", "v")] + lin[0], [f"{n}{j}" for j in range(3, 6) for n in ("k", "v")] + lin[1]]
    states = [b.make_state() for b in bodies]

    def step(ids, cos, sin, mask, write, active, pick):
        f = lambda t: t.numpy().astype(np.float16)
        ins = {"cos": f(cos), "sin": f(sin), "mask": f(mask), "write": f(write), "active": f(active), "pick": f(pick)}
        h = embed[ids]
        for b, s in zip(bodies, states):
            h = b.predict({"x": h, **ins}, s)["h"]
        return head.predict({"h": h})["next"][0].tolist()

    save = lambda names: lambda: [{n: states[i].read_state(n).copy() for n in names[i]} for i in (0, 1)]

    def restore(saved):
        for i in (0, 1):
            for n, v in saved[i].items():
                states[i].write_state(n, v)

    r = Runner(step, save(lin), restore, K, MAX)
    r.cache_prefix(tok, save(every), restore)
    return lambda text: r.clean(tok, text, speculate=True)


def mlx_engine():
    from mlx_lm import generate, load
    sys.path.insert(0, HERE)
    from harness import SYSTEM

    model, tok = load(f"{DATA}/models/glide-cleanup-mlx-8bit")

    def clean(text):
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False)
        return generate(model, tok, prompt, max_tokens=2 * len(tok.encode(text)) + 50)
    return clean


def main():
    mode, seconds = sys.argv[1], float(sys.argv[2])
    if mode == "train":
        sys.argv = ["train_probe.py", "9"]
        sampled(lambda: __import__("runpy").run_path(f"{HERE}/train_probe.py", run_name="__main__"))
        return
    clean = {"idle": None, "ane": ane_engine, "mlx": mlx_engine}[mode]
    clean = clean() if clean else None
    if clean:
        for s in SENTENCES:  # warm up
            clean(s)
    n = [0]

    def work():
        t0 = time.time()
        while time.time() - t0 < seconds:
            if clean:
                clean(SENTENCES[n[0] % len(SENTENCES)])
                n[0] += 1
            else:
                time.sleep(0.5)
    took, avg = sampled(work)
    total = sum(avg.values())
    n = n[0]
    per = f", {total * took / max(n, 1):.0f} mJ per cleanup before idle, {n / took:.1f} cleanups/s" if n else ""
    print(f"{mode}: CPU {avg['CPU']:.0f} mW, GPU {avg['GPU']:.0f} mW, ANE {avg['ANE']:.0f} mW, "
          f"total {total:.0f} mW over {took:.0f} s, {n} cleanups{per}", flush=True)


def sampled(work):
    """Runs work() under powermetrics; prints and returns its duration and the average power of each block."""
    log = tempfile.NamedTemporaryFile(suffix=".txt", delete=False).name
    pm = subprocess.Popen(["sudo", "-n", "powermetrics", "-i", "500", "--samplers", "cpu_power,gpu_power,ane_power",
                           "-o", log], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # which processes use the CPU meanwhile, since powermetrics' CPU figure is the whole machine's
    top = subprocess.Popen(["top", "-l", "4", "-s", "8", "-o", "cpu", "-n", "5", "-stats", "cpu,command"],
                           stdout=subprocess.PIPE, text=True)
    time.sleep(1)
    t0 = time.time()
    work()
    took = time.time() - t0
    busy = [l.strip() for l in top.communicate()[0].splitlines()[-5:]]
    subprocess.run(["sudo", "-n", "kill", "-INT", str(pm.pid)])
    pm.wait()
    text = open(log).read()
    mw = {k: [int(v) for v in re.findall(rf"^{k} Power: (\d+) mW", text, re.M)] for k in ("CPU", "GPU", "ANE")}
    avg = {k: sum(v) / max(len(v), 1) for k, v in mw.items()}
    print(f"  powermetrics: {len(mw['CPU'])} samples over {took:.0f} s, CPU {avg['CPU']:.0f} mW, GPU {avg['GPU']:.0f} mW, "
          f"ANE {avg['ANE']:.0f} mW; busiest processes: {' | '.join(busy)}", flush=True)
    return took, avg


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    main()
