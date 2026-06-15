#!/usr/bin/env python3
"""
eval-locomo-recall.py — run Pace's recall against the public LoCoMo benchmark.

LoCoMo (github.com/snap-research/locomo) is a long-term conversational-memory
benchmark: multi-session dialogues + QA pairs whose `evidence` cites the gold
dialog turns (e.g. "D1:3"). This harness measures the part Pace owns —
RETRIEVAL recall: index dialog content as memories, embed each question with
Pace's production embedding model (LM Studio), rank, and check whether a
gold-evidence turn lands in the top-k.

It's also a prototyping bench for recall improvements before porting them into
the Swift `PaceMemoryRetriever`. Flags toggle the SOTA-playbook techniques:
  --window N   group N consecutive turns per memory unit (default 1 = per-turn)
  --date       prefix each unit with its session date (helps temporal recall)
  --hybrid     fuse BM25 + semantic rankings via Reciprocal Rank Fusion

Default (no flags) reproduces the naive per-turn semantic baseline.

Usage:
  python3 scripts/eval-locomo-recall.py                          # baseline
  python3 scripts/eval-locomo-recall.py --window 3 --date --hybrid
"""

import argparse
import json
import math
import re
import sys
import urllib.error
import urllib.request
from collections import defaultdict

DIA_ID = re.compile(r"D\d+:\d+")
CATEGORY_NAMES = {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop"}
STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can",
    "did", "do", "does", "for", "from", "had", "has", "have", "how", "i", "if",
    "in", "is", "it", "its", "me", "my", "of", "on", "or", "so", "that", "the",
    "their", "them", "then", "there", "they", "this", "to", "was", "we", "were",
    "what", "when", "where", "which", "who", "will", "with", "would", "you",
    "your",
}


def embed(texts, base_url, model, chunk=64, timeout=180):
    vectors = []
    for start in range(0, len(texts), chunk):
        batch = texts[start:start + chunk]
        body = json.dumps({"model": model, "input": batch}).encode()
        req = urllib.request.Request(base_url.rstrip("/") + "/embeddings",
                                     data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
        vectors.extend(item["embedding"]
                       for item in sorted(data["data"], key=lambda d: d["index"]))
    return vectors


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def tokenize(text):
    return [t for t in re.split(r"[^a-z0-9]+", text.lower()) if t and t not in STOPWORDS]


def gold_ids(evidence):
    return set(DIA_ID.findall(json.dumps(evidence)))


def build_units(conv, window, with_date):
    """Return [(text, covered_dia_ids)] — windows never cross a session."""
    units = []
    session_keys = sorted(
        (k for k in conv if k.startswith("session_") and not k.endswith("date_time")
         and isinstance(conv[k], list)),
        key=lambda k: int(k.split("_")[1]))
    for sk in session_keys:
        date = conv.get(f"{sk}_date_time", "") if with_date else ""
        turns = [t for t in conv[sk] if t.get("dia_id") and t.get("text")]
        for start in range(0, len(turns), window):
            group = turns[start:start + window]
            body = " ".join(f"{t.get('speaker','')}: {t['text']}" for t in group)
            text = f"[{date}] {body}" if date else body
            units.append((text, [t["dia_id"] for t in group]))
    return units


def bm25_order(query, unit_texts, k1=1.5, b=0.75):
    docs = [tokenize(t) for t in unit_texts]
    n = len(docs)
    avgdl = sum(len(d) for d in docs) / n if n else 0.0
    q_terms = set(tokenize(query))
    df = {t: sum(1 for d in docs if t in d) for t in q_terms}
    scored = []
    for idx, doc in enumerate(docs):
        score, dl = 0.0, len(doc)
        for t in q_terms:
            tf = doc.count(t)
            if not tf:
                continue
            idf = math.log((n - df[t] + 0.5) / (df[t] + 0.5) + 1)
            score += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * (dl / avgdl if avgdl else 0)))
        scored.append((idx, score))
    scored.sort(key=lambda x: -x[1])
    return [idx for idx, s in scored if s > 0]


def rrf_fuse(orderings, k0=60):
    score = defaultdict(float)
    for ordering in orderings:
        for rank, idx in enumerate(ordering):
            score[idx] += 1.0 / (k0 + rank)
    return [idx for idx, _ in sorted(score.items(), key=lambda x: -x[1])]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", default="/tmp/locomo10.json")
    p.add_argument("--base-url", default="http://localhost:1234/v1")
    p.add_argument("--model", default="text-embedding-nomic-embed-text-v1.5")
    p.add_argument("--conversations", type=int, default=2)
    p.add_argument("--window", type=int, default=1)
    p.add_argument("--date", action="store_true")
    p.add_argument("--hybrid", action="store_true")
    p.add_argument("--ks", default="1,3,5,10")
    args = p.parse_args()
    ks = [int(k) for k in args.ks.split(",")]

    try:
        dataset = json.load(open(args.data))
    except FileNotFoundError:
        print(f"❌ {args.data} not found. curl the LoCoMo data first (see file header).")
        sys.exit(1)
    try:
        embed(["probe"], args.base_url, args.model, timeout=8)
    except (urllib.error.URLError, OSError, KeyError, ValueError) as exc:
        print(f"❌ LM Studio embeddings unreachable ({exc}).")
        sys.exit(1)

    samples = dataset[:args.conversations]
    cfg = f"window={args.window} date={args.date} hybrid={args.hybrid}"
    print(f"# Pace recall vs. LoCoMo — {len(samples)} conv, {cfg}, model={args.model}\n")

    hits = {k: 0 for k in ks}
    by_cat = defaultdict(lambda: {k: 0 for k in ks})
    by_cat_total = defaultdict(int)
    scored = 0

    for sample in samples:
        units = build_units(sample["conversation"], args.window, args.date)
        unit_texts = [u[0] for u in units]
        unit_covered = [set(u[1]) for u in units]
        unit_vecs = embed(unit_texts, args.base_url, args.model)

        questions, meta = [], []
        for qa in sample.get("qa", []):
            if qa.get("category") == 5:
                continue
            gold = gold_ids(qa.get("evidence", ""))
            if gold:
                questions.append(qa["question"])
                meta.append((gold, qa.get("category")))
        if not questions:
            continue
        q_vecs = embed(questions, args.base_url, args.model)
        sem_orders_cache = None

        for q_text, q_vec, (gold, cat) in zip(questions, q_vecs, meta):
            sem_order = [i for i, _ in sorted(
                enumerate(cosine(v, q_vec) for v in unit_vecs), key=lambda x: -x[1])]
            if args.hybrid:
                order = rrf_fuse([sem_order, bm25_order(q_text, unit_texts)])
            else:
                order = sem_order
            scored += 1
            by_cat_total[cat] += 1
            for k in ks:
                covered = set().union(*[unit_covered[i] for i in order[:k]]) if order[:k] else set()
                if gold & covered:
                    hits[k] += 1
                    by_cat[cat][k] += 1

    print(f"Scored {scored} retrieval questions (cat-5 adversarial excluded).\n")
    print("| recall@k | " + " | ".join(f"@{k}" for k in ks) + " |")
    print("|---|" + "|".join("---" for _ in ks) + "|")
    print("| **overall** | " + " | ".join(f"{hits[k]/scored:.0%}" for k in ks) + " |")
    for cat in sorted(by_cat_total):
        name = CATEGORY_NAMES.get(cat, f"cat-{cat}")
        tot = by_cat_total[cat]
        print(f"| {name} ({tot}) | " + " | ".join(f"{by_cat[cat][k]/tot:.0%}" for k in ks) + " |")


if __name__ == "__main__":
    main()
