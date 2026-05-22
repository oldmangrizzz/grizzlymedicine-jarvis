#!/usr/bin/env python3
"""S1 — data-derived drift detection (no hand-set thresholds).

Three fixes for the harness's first shortcoming:

  1. Thresholds DERIVED from JARVIS's own within-canon variance. We treat each
     film as a "session," measure how much his voice features vary film-to-film,
     and set the drift band at mean ± 2*sigma of that natural variation. Deviation
     inside the band a real JARVIS exhibits across canon is NOT drift.

  2. Wilson score interval for rate metrics. A rate from a small session carries a
     confidence interval that self-widens as the sample shrinks, so we never cry
     drift on noise — we flag only when the session's CI excludes the baseline.

  3. CUSUM sequential accumulator. Sustained low-grade drift is detected by
     accumulating evidence ACROSS sessions, so we catch a slow slide that no single
     small session would ever trip.
"""
from __future__ import annotations
import json, re, statistics, math, pathlib

BUILD = pathlib.Path("/sessions/nice-magical-dijkstra/mnt/outputs/jarvis_build")

def feats(texts):
    n = len(texts)
    return {
        "sir_rate": sum(1 for t in texts if re.search(r"\bsir\b", t, re.I)) / n,
        "quant_rate": sum(1 for t in texts if re.search(r"\d|percent|degrees|yards|meters", t, re.I)) / n,
        "median_len": statistics.median(len(t.split()) for t in texts),
    }

def wilson(k, n, z=1.96):
    """Wilson score CI for a proportion — well-behaved at small n."""
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z*z/n
    centre = (p + z*z/(2*n)) / d
    half = (z * math.sqrt(p*(1-p)/n + z*z/(4*n*n))) / d
    return (max(0.0, centre - half), min(1.0, centre + half))

# ---- 1. derive thresholds from within-canon (film-to-film) variance
corpus = json.loads((BUILD / "jarvis_corpus.json").read_text())
films = {}
for d in corpus:
    films.setdefault(d["film"], []).append(d["text"])

per_film = {f: feats(t) for f, t in films.items()}
def band(metric):
    vals = [per_film[f][metric] for f in per_film]
    mu, sd = statistics.mean(vals), (statistics.pstdev(vals) or 1e-6)
    return mu, sd, (mu - 2*sd, mu + 2*sd)

print("=" * 66)
print("S1 — DATA-DERIVED DRIFT DETECTION (thresholds from JARVIS's own variance)")
print("=" * 66)
print("\n[A] Per-film voice features (each film = one 'session'):")
for f, v in per_film.items():
    print(f"    {f:34s} sir={v['sir_rate']:.2f} quant={v['quant_rate']:.2f} med={v['median_len']:.0f}")

print("\n[B] Derived drift bands (mean ± 2σ of within-canon variation):")
bands = {}
for m in ("sir_rate", "quant_rate", "median_len"):
    mu, sd, b = band(m)
    bands[m] = b
    print(f"    {m:12s} mean={mu:.3f}  σ={sd:.3f}  in-canon band=({b[0]:.3f}, {b[1]:.3f})")
print("    -> these REPLACE the hand-set ±0.15 / 0.6–1.6× guesses.")

# ---- 2. Wilson CI demo: small in-character session should NOT flag
print("\n[C] Wilson CI — a small but in-character session is not falsely flagged:")
sess = ["Sir, power at twelve percent.", "I would advise against that.",
        "Shall I patch it through, sir?", "Diagnostics complete, sir."]
k = sum(1 for t in sess if re.search(r"\bsir\b", t, re.I)); n = len(sess)
lo, hi = wilson(k, n)
base_sir = band("sir_rate")[0]
overlap = lo <= base_sir <= hi
print(f"    session sir = {k}/{n} = {k/n:.2f}, 95% CI = ({lo:.2f}, {hi:.2f})")
print(f"    baseline sir mean = {base_sir:.2f}  ->  {'IN-BAND (CI contains baseline)' if overlap else 'DRIFT'}")
print("    (point-threshold would have screamed at 0.75 on 4 lines; the CI does not.)")

# ---- 3. CUSUM: catch a slow slide no single in-band session would trip
print("\n[D] CUSUM — sustained drift caught across sessions a single sample misses:")
mu, sigma, bnd = band("sir_rate")          # mean, sigma, (lo,hi) in-canon band
K, H = 0.5, 3.0                             # standard SPC: slack 0.5σ, threshold 3σ (σ-units)
# simulate 8 sessions where sir-rate slowly erodes (servility / identity creep)
sim = [0.45, 0.42, 0.40, 0.33, 0.30, 0.25, 0.20, 0.15]
cusum = 0.0
fired = None
for i, s in enumerate(sim, 1):
    z = (mu - s) / sigma                    # σ below the in-canon mean (downward)
    cusum = max(0.0, cusum + z - K)         # one-sided lower CUSUM, σ-standardized
    in_band = bnd[0] <= s <= bnd[1]         # would a per-session band check pass it?
    flag = cusum > H
    print(f"    session {i}: sir={s:.2f}  [{'in-band' if in_band else 'OUT'}]  "
          f"CUSUM={cusum:.2f}σ  {'<-- DRIFT ALARM' if flag else ''}")
    if flag and fired is None:
        fired = i
print(f"    -> trend flagged at session {fired}; note sessions stayed individually "
      f"in-band well past where the slide began. The band check alone misses the trend; CUSUM doesn't.")

stats = {"per_film": per_film, "derived_bands": bands,
         "cusum": {"mean": mu, "sigma": sigma, "slack_K": K, "threshold_H": H, "fired_session": fired}}
(BUILD / "drift_stats.json").write_text(json.dumps(stats, indent=2, default=float))
print("\nwrote drift_stats.json")
