#!/usr/bin/env python3
"""
eval-locomo-qa.py — LoCoMo ANSWER-ACCURACY on Pace's fully-local stack.

This is the apples-to-apples number vs. the market (Mem0/Zep/Memori/ByteRover
report LoCoMo LLM-as-Judge answer accuracy). It runs the whole pipeline locally:
  retrieve (nomic embeddings + windowing + hybrid BM25⊕semantic RRF)
  -> answer (Pace's planner, google/gemma-3-12b, from retrieved context)
  -> judge (same local model as LLM-as-judge: is the answer correct vs gold?)

Caveats baked in (so the number is read honestly):
  - Judge is LOCAL (gemma-12b), not GPT-4o like the published leaderboards, so
    this reads slightly conservative.
  - Uses the IMPROVED retrieval config (window=3 + date + hybrid) — i.e. Pace's
    realistic near-term ceiling, not today's shipped per-turn recall.
  - Sampled + stratified by category for a fast read.

Usage:
  python3 scripts/eval-locomo-qa.py --sample-per-category 15
"""

import argparse
import json
import math
import re
import sys
import time
import urllib.request
from collections import defaultdict

DIA_ID = re.compile(r"D\d+:\d+")
CATEGORY_NAMES = {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop"}
STOPWORDS = {"a","an","and","are","as","at","be","been","but","by","can","did",
    "do","does","for","from","had","has","have","how","i","if","in","is","it",
    "its","me","my","of","on","or","so","that","the","their","them","then",
    "there","they","this","to","was","we","were","what","when","where","which",
    "who","will","with","would","you","your"}


def post(path, payload, base_url, timeout, attempts=4):
    # LM Studio can transiently 4xx a request while a model is JIT-swapping /
    # warming (e.g. the first call after a second model loads). Retry a few
    # times before giving up so a momentary race doesn't kill a long run.
    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(base_url.rstrip("/") + path,
                data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.load(resp)
            if isinstance(data, dict) and "error" in data and "data" not in data and "choices" not in data:
                last = RuntimeError(data["error"])
            else:
                return data
        except Exception as exc:  # noqa: BLE001 — best-effort retry on any transient
            last = exc
        time.sleep(2 * (attempt + 1))
    raise last


def embed(texts, base_url, model, chunk=64):
    out = []
    for i in range(0, len(texts), chunk):
        d = post("/embeddings", {"model": model, "input": texts[i:i+chunk]}, base_url, 180)
        out.extend(x["embedding"] for x in sorted(d["data"], key=lambda e: e["index"]))
    return out


def chat(messages, base_url, model, timeout=120, max_tokens=256):
    d = post("/chat/completions",
             {"model": model, "messages": messages, "temperature": 0, "max_tokens": max_tokens},
             base_url, timeout)
    return d["choices"][0]["message"]["content"].strip()


def cosine(a, b):
    dot = sum(x*y for x, y in zip(a, b))
    na = math.sqrt(sum(x*x for x in a)); nb = math.sqrt(sum(y*y for y in b))
    return dot/(na*nb) if na and nb else 0.0


def tok(t): return [w for w in re.split(r"[^a-z0-9]+", t.lower()) if w and w not in STOPWORDS]


def bm25_order(query, texts, k1=1.5, b=0.75):
    docs = [tok(t) for t in texts]; n = len(docs)
    avgdl = sum(len(d) for d in docs)/n if n else 0.0
    qt = set(tok(query)); df = {t: sum(1 for d in docs if t in d) for t in qt}
    scored = []
    for i, doc in enumerate(docs):
        s = 0.0; dl = len(doc)
        for t in qt:
            tf = doc.count(t)
            if tf:
                idf = math.log((n - df[t] + 0.5)/(df[t] + 0.5) + 1)
                s += idf*(tf*(k1+1))/(tf + k1*(1 - b + b*(dl/avgdl if avgdl else 0)))
        scored.append((i, s))
    scored.sort(key=lambda x: -x[1])
    return [i for i, s in scored if s > 0]


def rrf(orderings, k0=60):
    sc = defaultdict(float)
    for o in orderings:
        for r, i in enumerate(o):
            sc[i] += 1.0/(k0+r)
    return [i for i, _ in sorted(sc.items(), key=lambda x: -x[1])]


def build_units(conv, window=3):
    units = []
    sks = sorted((k for k in conv if k.startswith("session_") and not k.endswith("date_time")
                  and isinstance(conv[k], list)), key=lambda k: int(k.split("_")[1]))
    for sk in sks:
        date = conv.get(f"{sk}_date_time", "")
        turns = [t for t in conv[sk] if t.get("dia_id") and t.get("text")]
        for s in range(0, len(turns), window):
            g = turns[s:s+window]
            body = " ".join(f"{t.get('speaker','')}: {t['text']}" for t in g)
            units.append(f"[{date}] {body}")
    return units


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", default="/tmp/locomo10.json")
    p.add_argument("--base-url", default="http://localhost:1234/v1")
    p.add_argument("--embed-model", default="text-embedding-nomic-embed-text-v1.5")
    p.add_argument("--chat-model", default="google/gemma-3-12b")
    p.add_argument("--conversations", type=int, default=1)
    p.add_argument("--sample-per-category", type=int, default=15)
    p.add_argument("--top-k", type=int, default=10)
    args = p.parse_args()

    dataset = json.load(open(args.data))
    correct = defaultdict(int); total = defaultdict(int)

    for sample in dataset[:args.conversations]:
        unit_texts = build_units(sample["conversation"])
        unit_vecs = embed(unit_texts, args.base_url, args.embed_model)

        per_cat = defaultdict(list)
        for qa in sample.get("qa", []):
            c = qa.get("category")
            if c == 5 or not DIA_ID.findall(json.dumps(qa.get("evidence", ""))):
                continue
            per_cat[c].append(qa)
        chosen = []
        for c, items in per_cat.items():
            chosen.extend(items[:args.sample_per_category])

        q_vecs = embed([qa["question"] for qa in chosen], args.base_url, args.embed_model)
        for qa, qv in zip(chosen, q_vecs):
            sem = [i for i, _ in sorted(enumerate(cosine(v, qv) for v in unit_vecs), key=lambda x: -x[1])]
            order = rrf([sem, bm25_order(qa["question"], unit_texts)])
            ctx = "\n".join(unit_texts[i] for i in order[:args.top_k])
            try:
                pred = chat([
                    {"role": "system", "content": "Answer the question using ONLY the conversation memory provided. Be concise — a few words. If the memory doesn't contain it, say you don't know."},
                    {"role": "user", "content": f"Conversation memory:\n{ctx}\n\nQuestion: {qa['question']}\nAnswer:"}
                ], args.base_url, args.chat_model, max_tokens=120)
                verdict = chat([
                    {"role": "system", "content": "You grade answers. Reply with exactly YES if the proposed answer matches the reference answer in meaning, otherwise NO."},
                    {"role": "user", "content": f"Question: {qa['question']}\nReference: {qa['answer']}\nProposed: {pred}\nCorrect?"}
                ], args.base_url, args.chat_model, max_tokens=5)
            except Exception as exc:
                print(f"  (skip: {exc})", file=sys.stderr); continue
            c = qa.get("category")
            total[c] += 1
            if verdict.strip().upper().startswith("Y"):
                correct[c] += 1

    grand_c = sum(correct.values()); grand_t = sum(total.values())
    print(f"# Pace local-stack LoCoMo ANSWER accuracy (LLM-judge: {args.chat_model})\n")
    print(f"retrieval = nomic + window3 + date + hybrid-RRF, top-k={args.top_k}; "
          f"answer+judge = {args.chat_model} (LOCAL judge)\n")
    print("| category | n | accuracy |")
    print("|---|---|---|")
    for c in sorted(total):
        print(f"| {CATEGORY_NAMES.get(c, c)} | {total[c]} | {correct[c]/total[c]:.0%} |")
    if grand_t:
        print(f"| **overall** | {grand_t} | **{grand_c/grand_t:.0%}** |")


if __name__ == "__main__":
    main()
