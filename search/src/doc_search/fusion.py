"""Rank fusion for the join: reciprocal rank fusion, one hit per file, a floor per kind.

RRF is rank-based, so semble's fused scores and cosine similarities never have to be compared.
"""

from __future__ import annotations

import math
from collections.abc import Hashable, Sequence
from dataclasses import replace
from typing import TypeVar

from .types import Hit

K = TypeVar("K", bound=Hashable)

RRF_K = 60


def rrf(lists: Sequence[Sequence[K]], k: int = RRF_K) -> list[tuple[K, float]]:
    """Reciprocal rank fusion: a key's score is the sum of 1 / (k + rank) over the lists naming it.

    Ranks start at 1; a key repeated within one list counts at its first place only. Best score
    first; equal scores keep the order of first appearance (earlier list, then earlier place).
    """
    scores: dict[K, float] = {}
    for ranked in lists:
        seen: set[K] = set()
        for rank, key in enumerate(ranked, start=1):
            if key in seen:
                continue
            seen.add(key)
            scores[key] = scores.get(key, 0.0) + 1.0 / (k + rank)
    return sorted(scores.items(), key=lambda item: -item[1])  # sorted() is stable


def collapse_by_file(hits: list[Hit]) -> list[Hit]:
    """The best hit of each path, in the order the paths first appear; the rest are counted.

    `hits` come best first, so a path's first hit is its best. `more_in_file` becomes the number of
    other hits of that path in `hits` (added to any count already on the best one), and the legs
    of the dropped chunks join the best hit's. The input hits are not modified.
    """
    best: dict[str, Hit] = {}
    for hit in hits:
        kept = best.get(hit.path)
        if kept is None:
            best[hit.path] = hit
            continue
        legs = kept.legs + tuple(leg for leg in hit.legs if leg not in kept.legs)
        best[hit.path] = replace(kept, more_in_file=kept.more_in_file + 1 + hit.more_in_file, legs=legs)
    return list(best.values())


def interleave_with_floor(
    docs: list[Hit],
    code: list[Hit],
    limit: int,
    *,
    docs_scores: Sequence[float] | None = None,
) -> list[Hit]:
    """The best `limit` hits of two ranked lists, with at least ceil(limit / 3) of each kind that has any.

    The lists are merged by RRF score: a hit's score is `docs_scores[i]` for `docs[i]` when given
    (a docs list already fused over several legs scores higher than a single leg's), otherwise
    1 / (60 + rank); a code-list hit scores 1 / (60 + rank). Ties go to the docs list.

    A kind is the hit's own `kind`, not the list it came in: a doc hit that arrived through the
    code leg counts for the docs floor. When the best `limit` hold fewer than the floor of a kind
    that has more hits to give, its best further hits replace the weakest hits of the other kind.
    The result is in score order.
    """
    if docs_scores is not None and len(docs_scores) != len(docs):
        raise ValueError("docs_scores must have one score per docs hit")
    if limit < 1:
        return []
    own = list(docs_scores) if docs_scores is not None else [1.0 / (RRF_K + rank) for rank in range(1, len(docs) + 1)]
    scored = [(score, 0, i, hit) for i, (score, hit) in enumerate(zip(own, docs, strict=True))]
    scored += [(1.0 / (RRF_K + i + 1), 1, i, hit) for i, hit in enumerate(code)]
    ranked = [hit for _, _, _, hit in sorted(scored, key=lambda item: (-item[0], item[1], item[2]))]

    floor = math.ceil(limit / 3)
    picked = set(range(min(limit, len(ranked))))  # indexes into `ranked`
    if 2 * floor <= limit:  # limit 1 has room for one kind only: the best hit wins
        for kind in ("doc", "code"):
            need = floor - sum(ranked[i].kind == kind for i in picked)
            if need <= 0:
                continue
            incoming = [i for i in range(limit, len(ranked)) if ranked[i].kind == kind][:need]
            # the weakest hits of the other kind make room; it keeps at least `floor` of its own
            victims = sorted((i for i in picked if ranked[i].kind != kind), reverse=True)[: len(incoming)]
            swaps = min(len(incoming), len(victims))
            picked -= set(victims[:swaps])
            picked |= set(incoming[:swaps])
    return [ranked[i] for i in sorted(picked)]
