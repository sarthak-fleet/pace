#!/usr/bin/env python3
"""
eval-memory-recall.py — recall-QUALITY eval for Pace's unified memory.

The unit tests (PaceMemoryIndexTests / PaceMemoryRetrieverTests) prove the
ranking MECHANICS on fixed vectors. This eval proves the thing that actually
matters to the user: when a memory is stored and later asked about with
DIFFERENT words, does the right memory surface?

It scores two rankers over the same fixtures:
  - keyword (BM25-ish, mirrors PaceMemoryIndex.rankByKeywordSimilarity incl.
    stopwords) — runs with NO model, and is expected to MISS the
    lexically-divergent cases. That miss is the motivation for semantic recall.
  - semantic (cosine over LM Studio /v1/embeddings, the production path) — the
    real proof. Skipped with a clear message when LM Studio isn't reachable.

Usage:
  python3 scripts/eval-memory-recall.py
  python3 scripts/eval-memory-recall.py --base-url http://localhost:1234/v1 \
      --model qwen3-embedding-0.6b --top-k 1

Exit code: 0 when the eval ran (even keyword-only). Non-zero only when a
requested semantic run was reachable but FAILED its pass bar, so CI can gate on
it once the embedding model is a fixture.
"""

import argparse
import json
import math
import re
import sys
import urllib.error
import urllib.request

# Mirrors PaceMemoryIndex.lexicalStopwords so the keyword baseline here matches
# production BM25 tokenization.
STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can",
    "did", "do", "does", "for", "from", "had", "has", "have", "how", "i", "if",
    "in", "is", "it", "its", "me", "my", "of", "on", "or", "so", "that", "the",
    "their", "them", "then", "there", "they", "this", "to", "was", "we", "were",
    "what", "when", "where", "which", "who", "will", "with", "would", "you",
    "your",
}

# Each fixture: a small memory set + a query asked with DIFFERENT words than the
# expected memory, plus distractors. `expect` is the memory text that should
# rank #1. `lexical_overlap` flags whether the query shares a content word with
# the expected memory — when False, keyword recall is EXPECTED to miss and only
# semantic should pass. That contrast is the whole point.
FIXTURES = [
    {
        "name": "mother/mom",
        "query": "how is my mother doing?",
        "expect": "my mom is in the hospital",
        "lexical_overlap": False,
        "memories": [
            "my mom is in the hospital",
            "the quarterly report is due Friday",
            "I prefer dark roast coffee",
        ],
    },
    {
        "name": "japan/tokyo",
        "query": "when do I travel to Japan?",
        "expect": "my flight to Tokyo lands on the 14th",
        "lexical_overlap": False,
        "memories": [
            "my flight to Tokyo lands on the 14th",
            "the dentist appointment is next Tuesday",
            "remember to water the plants",
        ],
    },
    {
        "name": "allergy",
        "query": "is there any food I cannot eat?",
        "expect": "I'm allergic to peanuts",
        "lexical_overlap": False,
        "memories": [
            "I'm allergic to peanuts",
            "the standup is at 9am",
            "my car is due for service",
        ],
    },
    {
        "name": "morning-sync/standup",
        "query": "when is our morning sync?",
        "expect": "the team standup is at 9am",
        "lexical_overlap": False,
        "memories": [
            "the team standup is at 9am",
            "I'm allergic to peanuts",
            "the office is closed on Monday",
        ],
    },
    {
        "name": "editor (control: lexical overlap exists)",
        "query": "which code editor do I prefer?",
        "expect": "I use VS Code as my main editor",
        "lexical_overlap": True,
        "memories": [
            "I use VS Code as my main editor",
            "my flight to Tokyo lands on the 14th",
            "the team standup is at 9am",
        ],
    },
    {
        "name": "browser (control: lexical overlap exists)",
        "query": "what is my preferred browser?",
        "expect": "my preferred browser is Firefox",
        "lexical_overlap": True,
        "memories": [
            "my preferred browser is Firefox",
            "the weather is nice today",
            "I'm allergic to peanuts",
        ],
    },
]


def tokenize(text):
    return [t for t in re.split(r"[^a-z0-9]+", text.lower()) if t and t not in STOPWORDS]


def bm25_rank(query, memories, k1=1.5, b=0.75):
    docs = [tokenize(m) for m in memories]
    n = len(docs)
    avgdl = sum(len(d) for d in docs) / n if n else 0.0
    q_terms = set(tokenize(query))
    df = {t: sum(1 for d in docs if t in d) for t in q_terms}
    scored = []
    for memory, doc in zip(memories, docs):
        score = 0.0
        dl = len(doc)
        for t in q_terms:
            tf = doc.count(t)
            if tf == 0:
                continue
            idf = math.log((n - df[t] + 0.5) / (df[t] + 0.5) + 1)
            denom = tf + k1 * (1 - b + b * (dl / avgdl if avgdl else 0))
            score += idf * (tf * (k1 + 1)) / denom
        scored.append((memory, score))
    scored.sort(key=lambda x: (-x[1], x[0]))
    # Drop zero-overlap docs (mirrors production: score > 0 only).
    return [m for m, s in scored if s > 0]


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def embed(texts, base_url, model, timeout=20):
    body = json.dumps({"model": model, "input": texts}).encode()
    req = urllib.request.Request(
        base_url.rstrip("/") + "/embeddings",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.load(resp)
    items = sorted(data["data"], key=lambda d: d["index"])
    return [item["embedding"] for item in items]


def semantic_rank(query, memories, base_url, model):
    vectors = embed(memories + [query], base_url, model)
    query_vec = vectors[-1]
    scored = list(zip(memories, (cosine(v, query_vec) for v in vectors[:-1])))
    scored.sort(key=lambda x: (-x[1], x[0]))
    return [m for m, _ in scored]


def top_k_hit(ranked, expect, k):
    return expect in ranked[:k]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://localhost:1234/v1")
    parser.add_argument("--model", default="qwen3-embedding-0.6b")
    parser.add_argument("--top-k", type=int, default=1)
    args = parser.parse_args()

    # Probe the embedding endpoint once.
    semantic_available = True
    semantic_error = ""
    try:
        embed(["probe"], args.base_url, args.model, timeout=5)
    except (urllib.error.URLError, OSError, KeyError, ValueError) as exc:
        semantic_available = False
        semantic_error = str(exc)

    print("# Pace memory-recall eval\n")
    print(f"top-k = {args.top_k}; semantic = "
          f"{'LM Studio ' + args.model if semantic_available else 'UNAVAILABLE'}\n")
    print("| fixture | lexical overlap | keyword | semantic |")
    print("|---|---|---|---|")

    keyword_pass = 0
    semantic_pass = 0
    semantic_run = 0
    for fx in FIXTURES:
        kw = bm25_rank(fx["query"], fx["memories"])
        kw_hit = top_k_hit(kw, fx["expect"], args.top_k)
        keyword_pass += kw_hit

        if semantic_available:
            sem = semantic_rank(fx["query"], fx["memories"], args.base_url, args.model)
            sem_hit = top_k_hit(sem, fx["expect"], args.top_k)
            semantic_run += 1
            semantic_pass += sem_hit
            sem_cell = "✅" if sem_hit else "❌"
        else:
            sem_cell = "—"

        print(f"| {fx['name']} | {'yes' if fx['lexical_overlap'] else 'no'} "
              f"| {'✅' if kw_hit else '❌'} | {sem_cell} |")

    n = len(FIXTURES)
    print(f"\n**keyword:** {keyword_pass}/{n}")
    if semantic_available:
        print(f"**semantic:** {semantic_pass}/{semantic_run}")
        print("\nSemantic should beat keyword on the `lexical overlap = no` rows "
              "— that's the recall-quality win the unified index buys.")
    else:
        print("**semantic:** skipped — LM Studio embeddings unreachable "
              f"({semantic_error}).")
        print("\nStart LM Studio + load the embedding model "
              f"(`{args.model}`, max-loaded-models >= 3), then re-run to score "
              "semantic recall. The keyword column above shows where lexical "
              "recall MISSES — those are the rows semantic must rescue.")

    # Gate: only fail when semantic ran but didn't clear the bar (all no-overlap
    # rows must hit). Keyword-only runs are informational, never a failure.
    if semantic_available:
        no_overlap = [fx for fx in FIXTURES if not fx["lexical_overlap"]]
        rescued = sum(
            top_k_hit(
                semantic_rank(fx["query"], fx["memories"], args.base_url, args.model),
                fx["expect"], args.top_k)
            for fx in no_overlap
        )
        if rescued < len(no_overlap):
            print(f"\n❌ semantic rescued only {rescued}/{len(no_overlap)} "
                  "lexically-divergent cases.")
            sys.exit(1)
        print(f"\n✅ semantic rescued all {len(no_overlap)} lexically-divergent cases.")


if __name__ == "__main__":
    main()
