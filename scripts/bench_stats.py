#!/usr/bin/env python3
from __future__ import annotations

import math
import random
import statistics
from typing import Iterable, List, Optional, Sequence, Tuple


def _sorted_floats(samples: Iterable[float]) -> List[float]:
    return sorted(float(x) for x in samples)


def percentile_nearest_rank(samples: Sequence[float], p: float) -> Optional[float]:
    xs = _sorted_floats(samples)
    if not xs:
        return None
    clamped = max(0.0, min(1.0, float(p)))
    if clamped <= 0.0:
        return xs[0]
    rank = int(math.ceil(clamped * len(xs))) - 1
    rank = max(0, min(rank, len(xs) - 1))
    return xs[rank]


def bootstrap_ci_median(
    samples: Sequence[float],
    *,
    confidence: float = 0.95,
    rounds: int = 2_000,
    seed: int = 17,
) -> Tuple[Optional[float], Optional[float]]:
    xs = _sorted_floats(samples)
    n = len(xs)
    if n < 2:
        return (None, None)

    conf = max(0.50, min(0.999, float(confidence)))
    alpha = 1.0 - conf
    rounds = max(100, int(rounds))

    rng = random.Random(seed + n)
    stats: List[float] = []
    for _ in range(rounds):
        resampled = [xs[rng.randrange(n)] for _ in range(n)]
        stats.append(float(statistics.median(resampled)))
    stats.sort()

    low_idx = max(0, int(math.floor((alpha / 2.0) * rounds)))
    high_idx = min(rounds - 1, int(math.ceil((1.0 - alpha / 2.0) * rounds)) - 1)
    return (stats[low_idx], stats[high_idx])
