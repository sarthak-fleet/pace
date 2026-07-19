#!/usr/bin/env python3
"""
generate-intent-corpus-v2.py — high-variation 10k+ intent corpus generator.

Produces labeled (transcript, intent) pairs for training Pace's
PaceIntentClassifier (7 classes: pureKnowledge, screenDescription,
screenAction, chitchat, phoneLargeModel, research, unknown).

Key improvements over the original generate-intent-corpus.py:
  - All 7 classes covered (original only had 4)
  - Massive combinatorial expansion for uniqueness at 10k+ scale
  - Multi-action transcripts: sequential, parallel, parameterized
  - Personal-assistant style queries ("play my favorite playlist",
    "text sarah that i'm running late", "open safari then go to
    youtube and play the first video")
  - Realistic voice-dictation artifacts: fillers, self-corrections,
    wake phrases, lowercase, minimal punctuation
  - Adversarial boundary cases for the unknown class
  - Deduplication guarantee

Output: evals/intent-corpus/synthetic-large.jsonl
        evals/intent-corpus/synthetic-large.csv  (Create ML format)

Usage:
  ./scripts/generate-intent-corpus-v2.py
  ./scripts/generate-intent-corpus-v2.py --total 10000
  ./scripts/generate-intent-corpus-v2.py --total 10000 --seed 42
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
OUTPUT_DIR = PROJECT_DIR / "evals" / "intent-corpus"

# ===========================================================================
# VARIATION LAYERS — applied across all classes for dictation realism
# ===========================================================================

WAKE_PHRASES = [
    "hey pace", "hi pace", "okay pace", "yo pace", "hello pace",
    "ok pace", "pace",
]

# Universal leading fillers — work with any phrase type
UNIVERSAL_FILLERS = [
    "", "", "", "", "", "", "",  # heavily weighted toward no filler
    "uh ", "um ", "like ", "okay so ", "well ", "alright ",
    "so ", "hey ",
]

# Action/request fillers — only make sense before commands, questions, descriptions
# NOT appropriate for chitchat greetings, thanks, closings, acknowledgments
ACTION_FILLERS = [
    "", "", "", "", "", "", "",  # mostly no filler
    "can you ", "could you ", "please ",
    "i need you to ", "i want you to ", "let's ", "how about ",
]

# Fillers appropriate for knowledge questions
QUESTION_FILLERS = [
    "", "", "", "",  # mostly no filler
    "can you ", "could you ", "hey ",
    "i was wondering ", "quick question, ",
]

# Mid-utterance fillers inserted between clauses
MID_FILLERS = [
    "", "", "", "",  # weighted toward nothing
    " like ", " you know ", " i mean ", " uh ", " um ",
    " basically ", " sort of ",
]

# Self-correction patterns (rare but realistic)
SELF_CORRECTIONS = [
    "", "", "", "", "",  # mostly no correction
    " no wait ",
    " actually ",
    " sorry ",
    " hmm, no, ",
]

# Trailing words / punctuation — mostly nothing, occasionally polite
TRAILING = [
    "", "", "", "", "", "", "", "",  # heavily weighted toward nothing
    "?", " please", " thanks", " for me",
    " if you can",
]

# Trailing for chitchat — just punctuation, no "please" or "for me"
CHITCHAT_TRAILING = [
    "", "", "", "", "", "",  # mostly nothing
    "?", "!", "...",
]

# Dictation-style case: almost always lowercase, occasionally
# capitalize proper nouns (apps, names, places)
PROPER_NOUNS = {
    "safari", "mail", "calendar", "notes", "reminders", "messages",
    "music", "spotify", "youtube", "finder", "settings", "photos",
    "maps", "facetime", "slack", "vs code", "terminal", "xcode",
    "chrome", "firefox", "notion", "figma", "pages", "numbers",
    "keynote", "imovie", "garageband", "preview", "textedit",
    "whatsapp", "telegram", "discord", "zoom", "teams",
    "sarah", "john", "mom", "dad", "mary", "alex", "emma",
    "james", "kate", "mike", "lisa", "tom", "anna", "dave",
    "jen", "chris", "nick", "amy", "ryan", "lauren",
}


def maybe_capitalize(text: str, rng: random.Random) -> str:
    """Occasionally capitalize proper nouns for realism."""
    if rng.random() < 0.15:
        for noun in PROPER_NOUNS:
            text = text.replace(f" {noun} ", f" {noun.title()} ")
            if text.startswith(noun + " "):
                text = noun.title() + text[len(noun):]
            if text.endswith(" " + noun):
                text = text[:-(len(noun))] + noun.title()
    return text


def apply_variation(base: str, rng: random.Random,
                     intent_class: str = "screenAction") -> str:
    """Apply dictation-realism variation layers to a base transcript.

    The intent_class controls which fillers are appropriate:
    - chitchat: only universal fillers (no "can you" before "hi")
    - pureKnowledge/screenDescription/research: question fillers
    - screenAction/phoneLargeModel/unknown: action fillers
    """
    # Wake phrase (sometimes, but not for very short chitchat)
    wake = ""
    if rng.random() < 0.20 and not (intent_class == "chitchat" and len(base) < 10):
        wake = rng.choice(WAKE_PHRASES) + ", "

    # Leading filler — context-aware
    if intent_class == "chitchat":
        filler = rng.choice(UNIVERSAL_FILLERS)
        # Don't stack "hey" filler on top of "hey pace" wake phrase
        if wake and filler == "hey ":
            filler = ""
    elif intent_class in ("pureKnowledge", "screenDescription", "research"):
        filler = rng.choice(QUESTION_FILLERS)
    else:
        filler = rng.choice(ACTION_FILLERS)

    # Mid-filler (only for longer utterances, not for short escalation phrases)
    if len(base) > 40 and intent_class not in ("phoneLargeModel", "chitchat") and rng.random() < 0.12:
        mid = rng.choice(MID_FILLERS)
        # Insert at a clause boundary if possible, otherwise middle space
        boundaries = []
        for i in range(len(base) - 1):
            if base[i:i+5] == " and ":
                boundaries.append(i + 5)
            elif base[i:i+6] == " then ":
                boundaries.append(i + 6)
            elif base[i:i+2] == ", ":
                boundaries.append(i + 2)
        if boundaries:
            insert_pos = rng.choice(boundaries)
        else:
            spaces = [i for i, c in enumerate(base) if c == " "]
            if len(spaces) > 3:
                insert_pos = spaces[len(spaces) // 2 + rng.randint(-1, 1)]
            else:
                insert_pos = -1
        if insert_pos >= 0:
            base = base[:insert_pos] + mid + base[insert_pos:]

    # Self-correction (rare, only for actions and descriptions)
    # Insert at clause boundaries (after "and", "then", commas) not
    # at arbitrary word positions — otherwise "what's on hmm, no, my
    # desktop" breaks a phrase mid-group.
    if intent_class in ("screenAction", "screenDescription") and rng.random() < 0.05:
        correction = rng.choice(SELF_CORRECTIONS)
        if correction:
            # Find clause boundary positions
            boundaries = []
            for i in range(len(base) - 1):
                if base[i:i+2] in (", ",):
                    boundaries.append(i + 1)
                elif base[i:i+5] == " and ":
                    boundaries.append(i + 5)
                elif base[i:i+6] == " then ":
                    boundaries.append(i + 6)
            if boundaries:
                pos = rng.choice(boundaries)
                base = base[:pos] + correction + base[pos:]

    # Trailing — context-aware
    if intent_class == "chitchat":
        trail = rng.choice(CHITCHAT_TRAILING)
    else:
        trail = rng.choice(TRAILING)

    # Assemble
    text = wake + filler + base + trail
    text = text.strip()

    # Occasional proper noun capitalization
    text = maybe_capitalize(text, rng)

    # Clean up double spaces
    while "  " in text:
        text = text.replace("  ", " ")

    return text.strip()


# ===========================================================================
# CHITCHAT — greetings, thanks, closings, social, identity, capability
# ===========================================================================

CHITCHAT_GREETINGS = [
    "hi", "hello", "hey", "hey there", "hi there", "hello there",
    "good morning", "good afternoon", "good evening", "good night",
    "what's up", "sup", "howdy", "hey hey", "yo",
    "hi pace", "hello pace", "hey pace",
    "morning", "evening", "afternoon",
    "hey buddy", "hi buddy", "hey pal",
    "what's happening", "what's good", "how goes it",
    "long time no see", "it's been a while",
    "good to see you", "nice to see you",
    "hey what's going on", "hi how are things",
    "yo pace", "sup pace", "hey pace hey",
    "greetings", "salutations", "howdy partner",
    "good day", "top of the morning",
    "rise and shine", "happy monday", "happy friday",
    "happy weekend", "happy holidays",
]

CHITCHAT_THANKS = [
    "thanks", "thank you", "thanks a lot", "thanks so much",
    "thank you very much", "appreciate it", "i appreciate that",
    "you're great", "you're awesome", "you're the best",
    "good job", "nice work", "well done", "great work",
    "that was helpful", "that helped a lot", "perfect thanks",
    "thanks for that", "much appreciated", "cheers",
    "thank you for your help", "i owe you one",
    "thanks a million", "thanks a bunch", "many thanks",
    "grateful", "so grateful", "i'm grateful",
    "you saved me time", "that was quick", "fast work",
    "nailed it", "spot on", "right on",
    "couldn't have done it better", "impressive",
    "thanks pace", "thank you pace", "good work pace",
    "you're a lifesaver", "you're a star", "you're a hero",
    "brilliant", "fantastic work", "stellar job",
    "kudos", "props to you", "mad respect",
    "that's exactly what i needed", "just what i wanted",
    "thanks i really mean it", "genuinely appreciate it",
]

CHITCHAT_CLOSINGS = [
    "bye", "bye for now", "goodbye", "see you", "see you later",
    "talk later", "talk to you later", "catch you later",
    "later pace", "later", "i'm done", "that's all",
    "nothing else", "we're good", "that's it for now",
    "i'll let you go", "have a good one", "take care",
    "see ya", "catcha", "peace out", "i'm out",
    "that's all for now", "wrapping up", "calling it a day",
    "i'm signing off", "done for today", "that wraps it up",
    "until next time", "till next time", "see you tomorrow",
    "see you next week", "have a good weekend",
    "have a good night", "sleep well", "rest up",
    "i'm heading out", "gotta run", "gotta go",
    "talk soon", "be in touch", "let's chat later",
    "i'll be back", "back later", "returning later",
]

CHITCHAT_SOCIAL = [
    "how are you", "how's it going", "how is it going",
    "how are things", "how's everything", "how's your day",
    "how's your day going", "what's new", "how have you been",
    "how do you feel", "are you doing well", "you doing okay",
    "what are you up to", "how's life",
    "how's it been", "how are you holding up",
    "you good", "you okay", "all good",
    "what's the haps", "what's shaking", "what's the word",
    "how's tricks", "how's your week been",
    "how's your morning", "how's your afternoon",
    "how's your evening", "did you have a good day",
    "having a good day", "good day so far",
    "what have you been up to", "anything new",
    "any updates", "what's the latest",
    "how are things on your end", "all well with you",
]

CHITCHAT_IDENTITY = [
    "who are you", "what are you", "are you siri", "are you chatgpt",
    "are you claude", "are you an ai", "are you a robot",
    "what's your name", "who made you", "who created you",
    "what model are you", "are you human", "are you real",
    "tell me about yourself", "what can you tell me about yourself",
    "are you pace", "are you the pace assistant",
    "what kind of assistant are you", "what are you exactly",
    "are you a person", "are you alive", "do you have feelings",
    "are you conscious", "are you self aware",
    "what's your personality", "do you have a personality",
    "who trained you", "who built you", "who programmed you",
    "what's your backstory", "introduce yourself",
    "describe yourself", "what should i call you",
    "are you mac specific", "are you only for mac",
    "do you work on windows", "do you work on linux",
    "are you local", "do you run on my mac",
    "do you need the internet", "are you offline",
]

CHITCHAT_CAPABILITY = [
    "what can you do", "what do you do", "help me",
    "can you hear me", "do you hear me", "are you there",
    "are you listening", "are you working", "is this working",
    "mic check", "test test", "can you see my screen",
    "can you see what i'm doing", "what are you capable of",
    "show me what you can do", "how do i use you",
    "what can you help with", "can you help me with something",
    "what are your features", "what can you see",
    "can you read my screen", "can you control my mac",
    "can you click things for me", "can you type for me",
    "can you open apps", "can you search the web",
    "can you send emails", "can you set reminders",
    "can you take screenshots", "can you play music",
    "what can't you do", "what are your limits",
    "are you good at coding", "can you write code",
    "can you help me debug", "can you explain things",
    "how do you work", "what's your workflow",
    "can you do voice commands", "do you need a keyboard",
    "can you hear me talk", "do you transcribe my voice",
    "what languages do you speak", "do you speak other languages",
    "can you multitask", "can you do multiple things at once",
]

CHITCHAT_ACKNOWLEDGMENTS = [
    "okay", "ok", "alright", "got it", "sounds good", "perfect",
    "nice", "cool", "great", "awesome", "fantastic", "excellent",
    "sure", "yeah", "yep", "right", "correct", "exactly",
    "makes sense", "i see", "understood", "roger that",
    "okay cool", "okay got it", "alright good", "sounds great",
    "that works", "fair enough", "good to know",
    "will do", "on it", "you got it", "for sure",
    "absolutely", "definitely", "totally", "completely",
    "agreed", "i agree", "makes sense to me",
    "noted", "gotcha", "ah okay", "ah i see",
    "right right", "yeah yeah", "ok ok",
    "sure thing", "you bet", "no problem",
    "of course", "naturally", "obviously",
    "good call", "smart", "clever",
    "that's fair", "that makes sense", "that checks out",
]

CHITCHAT_MICRO = [
    "hmm", "let me think", "one sec", "give me a moment",
    "hold on", "wait", "actually never mind", "forget it",
    "cancel that", "never mind", "scratch that", "disregard",
    "oops", "my bad", "sorry about that",
    "give me a second", "one moment", "hold up",
    "wait wait", "no wait", "actually no",
    "hmm let me think", "thinking", "pondering",
    "i need a minute", "brb", "be right back",
    "standby", "give me a sec", "just a moment",
    "actually", "wait actually", "hmm actually",
]


def build_chitchat(count: int, rng: random.Random) -> list[dict]:
    pool = (
        CHITCHAT_GREETINGS + CHITCHAT_THANKS + CHITCHAT_CLOSINGS
        + CHITCHAT_SOCIAL + CHITCHAT_IDENTITY + CHITCHAT_CAPABILITY
        + CHITCHAT_ACKNOWLEDGMENTS + CHITCHAT_MICRO
    )
    examples = []
    seen = set()
    attempts = 0
    while len(examples) < count and attempts < count * 20:
        attempts += 1
        base = rng.choice(pool)
        text = apply_variation(base, rng, "chitchat")
        if text in seen:
            continue
        seen.add(text)
        examples.append({"transcript": text, "intent": "chitchat"})
    return examples


# ===========================================================================
# PURE KNOWLEDGE — factual questions, no screen context needed
# ===========================================================================

KNOWLEDGE_TOPICS = [
    # Programming
    "html", "css", "javascript", "python", "swift", "rust", "go",
    "typescript", "java", "c++", "kotlin", "ruby", "php", "scala",
    "react", "vue", "angular", "svelte", "node", "deno", "bun",
    "git", "docker", "kubernetes", "terraform", "ansible",
    "tcp", "udp", "dns", "https", "http", "tls", "ssl", "ssh",
    "json", "yaml", "xml", "protobuf", "graphql", "rest", "grpc",
    "regex", "async await", "closures", "promises", "generators",
    "the kernel", "memory mapping", "garbage collection", "the heap",
    "the stack", "pointers", "references", "smart pointers",
    "machine learning", "neural networks", "transformers", "attention",
    "embeddings", "vector databases", "rag", "fine-tuning", "lora",
    "quantization", "distillation", "reinforcement learning", "grpo",
    "backpropagation", "gradient descent", "adam optimizer", "loss functions",
    "convolutions", "pooling", "batch normalization", "dropout",
    "tokenization", "byte-pair encoding", "wordpiece", "sentencepiece",
    "elixir", "clojure", "haskell", "ocaml", "fsharp", "lisp",
    "lua", "perl", "r", "julia", "matlab", "fortran", "cobol",
    "assembly", "webassembly", "wasm", "llvm", "jit compilation",
    "compiler design", "parsers", "abstract syntax trees",
    "linkers", "loaders", "binary formats", "elf files",
    "processes vs threads", "context switching", "scheduling",
    "virtual memory", "page tables", "tlbs", "cache hierarchies",
    "branch prediction", "out of order execution", "pipelining",
    "simd instructions", "gpu architecture", "cuda cores",
    "metal shaders", "vulkan", "opengl", "webgpu",
    "redis", "memcached", "postgresql", "mysql", "sqlite",
    "mongodb", "cassandra", "dynamodb", "s3", "blob storage",
    "kafka", "rabbitmq", "celery", "sidekiq", "sqs",
    "nginx", "apache", "caddy", "envoy", "haproxy",
    "oauth", "jwt", "session management", "csrf", "xss",
    "encryption", "hashing", "salting", "pbkdf2", "bcrypt", "argon2",
    "rsa", "elliptic curves", "diffie hellman", "pki",
    "the clean architecture", "domain driven design", "solid principles",
    "design patterns", "the observer pattern", "the factory pattern",
    "the singleton pattern", "the builder pattern", "the adapter pattern",
    "the decorator pattern", "the facade pattern", "the strategy pattern",
    "the command pattern", "the iterator pattern", "the mediator pattern",
    "dependency injection", "inversion of control",
    "cap theorem", "acid transactions", "eventual consistency",
    "mapreduce", "sharding", "replication", "caching strategies",
    "write ahead logs", "mvcc", "b-trees", "lsm trees", "bloom filters",
    "consistent hashing", "quorum reads", "split brain",
    "ipv6", "bgp routing", "anycast", "multicast", "cdns",
    "load balancing", "rate limiting", "circuit breakers",
    "the law of demeter", "currying", "monads", "functors",
    "tail call optimization", "memoization", "lazy evaluation",
    # Science
    "newton's laws", "photosynthesis", "the krebs cycle", "entropy",
    "the speed of light", "general relativity", "special relativity",
    "evolution", "natural selection", "dna", "rna", "mitochondria",
    "the gulf stream", "plate tectonics", "quantum mechanics",
    "the standard model", "dark matter", "dark energy", "black holes",
    "neutron stars", "supernovae", "the big bang", "nuclear fusion",
    "nuclear fission", "radioactive decay", "isotopes", "chemical bonds",
    "the periodic table", "electrons", "protons", "neutrons", "quarks",
    "thermodynamics", "kinetic energy", "potential energy", "momentum",
    "friction", "gravity", "electromagnetism", "capacitance", "resistance",
    "string theory", "the higgs boson", "particle accelerators",
    "crispr", "gene therapy", "stem cells", "telomeres",
    "the immune system", "antibodies", "viruses", "bacteria",
    "neurons", "synapses", "the brain", "consciousness",
    "the nervous system", "the endocrine system", "homeostasis",
    "cell division", "mitosis", "meiosis", "chromosomes",
    "proteins", "enzymes", "amino acids", "lipids", "carbohydrates",
    "the water cycle", "the carbon cycle", "the nitrogen cycle",
    "ecosystems", "food chains", "biodiversity",
    "climate change", "the greenhouse effect", "the ozone layer",
    "ocean currents", "coral reefs", "the amazon rainforest",
    # Math
    "calculus", "linear algebra", "statistics", "probability",
    "the pythagorean theorem", "the fundamental theorem of calculus",
    "prime numbers", "fibonacci sequence", "the golden ratio",
    "euler's formula", "the riemann hypothesis", "game theory",
    "the monte carlo method", "bayes theorem", "standard deviation",
    "normal distribution", "p-values", "confidence intervals",
    "matrices", "eigenvectors", "determinants", "cross products",
    "topology", "knot theory", "number theory", "set theory",
    "group theory", "ring theory", "field theory",
    "differential equations", "partial differential equations",
    "fourier transforms", "laplace transforms", "z-transforms",
    "markov chains", "stochastic processes", "random walks",
    "information theory", "shannon entropy", "kolmogorov complexity",
    "the central limit theorem", "the law of large numbers",
    "combinatorics", "graph theory", "permutations", "combinations",
    # History / Geography
    "the federal reserve", "compound interest", "options trading",
    "the constitution", "world war two", "world war one",
    "the renaissance", "the silk road", "the industrial revolution",
    "the french revolution", "the american revolution", "the cold war",
    "the roman empire", "ancient egypt", "the mongol empire",
    "the byzantine empire", "the ottoman empire", "the crusades",
    "the printing press", "the steam engine", "the telephone",
    "the internet", "the world wide web", "the transistor",
    "the great depression", "the gold standard", "the silk road",
    "the age of exploration", "the enlightenment", "the reformation",
    "ancient greece", "the persian empire", "the han dynasty",
    "the ming dynasty", "the british empire", "the viking age",
    "the mayan civilization", "the inca empire", "the aztec empire",
    "the colonization of the americas", "the transatlantic slave trade",
    "the vietnam war", "the korean war", "the space race",
    "the fall of the berlin wall", "the dissolution of the soviet union",
    # Economics / Finance
    "the law of supply and demand", "inflation", "deflation",
    "gdp", "recessions", "bonds", "stocks", "etfs", "index funds",
    "blockchain", "merkle trees", "consensus algorithms", "proof of work",
    "proof of stake", "smart contracts", "defi", "nfts",
    "fiscal policy", "monetary policy", "quantitative easing",
    "the yield curve", "interest rates", "the federal funds rate",
    "hedge funds", "private equity", "venture capital",
    "the sharpe ratio", "modern portfolio theory", "the efficient market hypothesis",
    "keynesian economics", "supply side economics", "austrian economics",
    # Misc / Cooking / Crafts
    "espresso", "sourdough", "fermentation", "the maillard reaction",
    "wine making", "cheese making", "coffee roasting", "tea brewing",
    "the french press", "the pour over", "cold brew",
    "knife skills", "braising", "roasting", "sous vide",
    "the emulsion", "the roux", "the mother sauces",
    "woodworking", "joinery", "dovetail joints", "mortise and tenon",
    "knitting", "weaving", "pottery", "glassblowing",
    # Philosophy / Psychology
    "stoicism", "existentialism", "nihilism", "utilitarianism",
    "the categorical imperative", "the trolley problem",
    "cognitive biases", "the dunning kruger effect",
    "the placebo effect", "operant conditioning", "classical conditioning",
    "maslow's hierarchy", "the flow state", "the growth mindset",
    "imposter syndrome", "the pygmalion effect",
    # Health / Fitness
    "intermittent fasting", "the keto diet", "the mediterranean diet",
    "macronutrients", "micronutrients", "the glycemic index",
    "vo2 max", "lactate threshold", "the aerobic vs anaerobic threshold",
    "hypertrophy training", "strength training", "cardio",
    "the mind muscle connection", "progressive overload",
]

KNOWLEDGE_PATTERNS = [
    "what is {}", "what's {}", "explain {}", "tell me about {}",
    "how does {} work", "can you describe {}", "what does {} do",
    "what does {} actually do", "remind me what {} means",
    "in plain english what is {}", "what's the deal with {}",
    "give me a quick intro to {}", "give me a brief overview of {}",
    "i don't understand {}", "can you explain {} to me",
    "help me understand {}", "what do you know about {}",
    "teach me about {}", "walk me through {}",
    "summarize {} for me", "give me the gist of {}",
    "what is {} in simple terms", "explain {} like i'm five",
    "explain {} like i'm 10", "what's {} all about",
    "i keep hearing about {}, what is it",
    "break down {} for me", "give me a crash course on {}",
    "what's the point of {}", "why does {} matter",
    "how does {} actually work", "what's the intuition behind {}",
    "what is the difference between {} and other things",
    "i'm confused about {}", "clarify {} for me",
    "what's a simple explanation of {}",
    "give me an example of {}", "show me an example of {}",
    "what are the basics of {}", "what are the fundamentals of {}",
    "where do i start with {}", "how do i get started with {}",
    "is {} hard to learn", "how long does it take to learn {}",
    "what do i need to know before {}",
    "what's the history of {}", "who invented {}",
    "when was {} invented", "why was {} created",
    "what problem does {} solve", "what's {} used for",
    "what are the use cases for {}", "when should i use {}",
    "what are the pros and cons of {}",
    "what are the alternatives to {}",
    "how is {} different from other approaches",
    "what's the relationship between {} and machine learning",
    "what's the relationship between {} and ai",
    "is {} still relevant", "is {} outdated",
    "what replaced {}", "what comes after {}",
    "what's the future of {}", "where is {} heading",
    "what's new in {}", "what changed in {}",
    "what's the best way to learn {}",
    "what's the best book on {}", "what's the best resource for {}",
    "what should i read to understand {}",
    "can you compare {} to other things",
    "what's the theory behind {}",
    "what's the math behind {}",
    "what's the science behind {}",
    "what's the logic behind {}",
    "what's the reasoning behind {}",
]

JOURNAL_RECALL = [
    "what did i do today", "what did i do yesterday",
    "what did i do this morning", "what did i do this afternoon",
    "what did i do this week", "what have i been doing",
    "what have i been working on", "what was i doing earlier",
    "what was i working on", "what apps did i use",
    "which apps did i use", "how did i spend my time",
    "how am i spending my time", "how much time did i spend",
    "how much time did i spend on each app",
    "summarize my day", "summarise my day",
    "summarize what i did today", "summarise what i did today",
    "what did i work on today", "what was my day like",
    "give me a summary of my day", "what have i been up to",
    "what was i doing an hour ago", "what was i doing 30 minutes ago",
    "which app was i using the most", "what took up most of my time",
    "how long was i in vs code", "how long was i in slack",
    "did i spend a lot of time on email today",
    "what did i do before lunch", "what did i do after lunch",
    "what did i do before the meeting", "what did i do after the meeting",
    "what was the last app i used", "what was i doing before this",
    "how much time did i waste today", "was i productive today",
    "what did i accomplish today", "what did i get done today",
    "what did i finish today", "what did i complete today",
    "what's my screen time today", "what's my screen time this week",
    "how much time did i spend on social media",
    "how much time did i spend browsing",
    "how much time did i spend coding",
    "how much time did i spend in meetings",
    "what was my most used app today", "what was my most used app this week",
    "show me my activity for today", "show me my activity for this week",
    "what did i do on monday", "what did i do on tuesday",
    "what did i do on friday", "what did i do over the weekend",
    "what was i doing at 3 pm", "what was i doing at 10 am",
    "what was i doing this morning", "what was i doing this afternoon",
    "what was i doing this evening", "what was i doing last night",
    "what was i doing yesterday afternoon",
    "what was i doing yesterday morning",
    "what was i doing yesterday evening",
]


def build_pure_knowledge(count: int, rng: random.Random) -> list[dict]:
    examples = []
    seen = set()
    attempts = 0
    while len(examples) < count and attempts < count * 15:
        attempts += 1
        # 80% knowledge questions, 20% journal recall
        if rng.random() < 0.80:
            topic = rng.choice(KNOWLEDGE_TOPICS)
            pattern = rng.choice(KNOWLEDGE_PATTERNS)
            base = pattern.format(topic)
        else:
            base = rng.choice(JOURNAL_RECALL)
        text = apply_variation(base, rng, "pureKnowledge")
        if text in seen:
            continue
        seen.add(text)
        examples.append({"transcript": text, "intent": "pureKnowledge"})
    return examples


# ===========================================================================
# SCREEN DESCRIPTION — "what's on screen", no action follows
# ===========================================================================

DESCRIPTION_BASES = [
    "what's on the screen", "what am i looking at",
    "describe what i'm looking at", "describe this",
    "summarise this page", "summarize what's here",
    "summarize this for me", "summarise this for me",
    "what does this show", "what does this say",
    "what's happening on screen", "what's happening on my screen",
    "read this to me", "read this", "read what's on screen",
    "read the screen", "read out what's there",
    "what's in front of me", "what's on my screen right now",
    "give me the gist of this", "give me the gist of what's here",
    "what can you see right now", "what can you see",
    "what do you see on my screen", "what's visible",
    "tell me what's open", "what's open right now",
    "what windows are open", "what apps are open",
    "what's this window about", "what is this window",
    "walk me through what's here", "walk me through what's on screen",
    "what's visible on this screen", "what's visible on my screen",
    "scan the screen and tell me", "scan the screen",
    "what's on display", "what's displayed",
    "what page am i on", "what website am i on",
    "what app is this", "what application is this",
    "what program is this", "what tool is this",
    "explain what's shown", "explain what's on screen",
    "describe my current view", "describe the screen",
    "describe what's on my screen", "describe the current window",
    "what's this all about", "what is this about",
    "lay out what's on the screen", "give me a rundown of what's here",
    "what am i looking at right now", "what's on my display",
    "tell me about what's on screen", "what's in this window",
    "what's the content of this page", "what's on this page",
    "read me the text on screen", "read me what it says",
    "what does this window say", "what does this page say",
    "summarize the page i'm on", "summarise the page i'm on",
    "what's here", "what's on here", "what's showing",
    "what's on my monitor", "what's on the display",
    "describe everything on screen", "what's the screen showing",
    "what's this", "what is this", "what are we looking at",
    "tell me what you see", "what's going on on screen",
    "give me a summary of the screen", "describe what's visible",
    "what's the current state of my screen",
    "what's on my desktop right now",
    "what's in the active window", "what does the active window show",
]

DESCRIPTION_QUALIFIERS = [
    "", "", "",  # mostly bare
    " briefly", " quickly", " in a few words",
    " in detail", " for me", " right now", " please",
    " and tell me what it means",
    " and what should i do with it",
    " and whether i need to do anything",
]


def build_screen_description(count: int, rng: random.Random) -> list[dict]:
    examples = []
    seen = set()
    attempts = 0
    while len(examples) < count and attempts < count * 15:
        attempts += 1
        base = rng.choice(DESCRIPTION_BASES)
        qualifier = rng.choice(DESCRIPTION_QUALIFIERS)
        text = apply_variation(base + qualifier, rng, "screenDescription")
        if text in seen:
            continue
        seen.add(text)
        examples.append({"transcript": text, "intent": "screenDescription"})
    return examples


# ===========================================================================
# SCREEN ACTION — the big one with multi-action, parameters, personal assistant
# ===========================================================================

# --- Single-action components ---

ACTION_VERBS = [
    "click", "tap", "press", "hit", "choose", "select", "focus",
    "toggle", "open", "launch", "start", "activate",
]

ACTION_TARGETS = [
    "the save button", "the file menu", "the close button",
    "the search bar", "the search field", "this link", "that link",
    "this button", "that button", "that field", "this field",
    "the first tab", "the second tab", "the third tab", "the last tab",
    "the send button", "the back button", "the forward button",
    "the refresh button", "the home button", "the settings icon",
    "settings", "preferences", "the inbox", "the outbox",
    "the menu icon", "the menu bar", "the toolbar",
    "the sidebar", "the status bar", "the address bar",
    "the url bar", "the navigation bar", "the breadcrumb",
    "the dropdown", "the checkbox", "the radio button",
    "the toggle switch", "the slider", "the progress bar",
    "the play button", "the pause button", "the next button",
    "the previous button", "the skip button", "the mute button",
    "the volume slider", "the brightness slider",
    "the compose button", "the reply button", "the forward button",
    "the delete button", "the trash button", "the archive button",
    "the star button", "the flag button", "the bookmark button",
    "the share button", "the export button", "the import button",
    "the download button", "the upload button", "the attach button",
    "the new button", "the add button", "the create button",
    "the edit button", "the update button", "the apply button",
    "the cancel button", "the confirm button", "the ok button",
    "the submit button", "the login button", "the sign in button",
    "the sign up button", "the register button", "the checkout button",
    "the buy button", "the add to cart button", "the wishlist button",
    "the like button", "the dislike button", "the upvote button",
    "the downvote button", "the comment button", "the reply field",
    "the message field", "the chat input", "the text area",
    "the code editor", "the terminal", "the console",
    "the debugger", "the breakpoint", "the run button",
    "the build button", "the test button", "the deploy button",
    "the profile icon", "the account menu", "the user menu",
    "the notifications icon", "the bell icon", "the help button",
    "the info button", "the about button", "the docs link",
    "the documentation link", "the api link", "the changelog link",
    "the release notes", "the version number",
]

TYPING_TEXTS = [
    "hello world", "my email address", "the password", "yes please",
    "no thanks", "thanks", "thank you", "this is a test",
    "pizza", "lorem ipsum", "meeting notes", "todo list",
    "buy groceries", "call mom", "pick up dry cleaning",
    "schedule dentist appointment", "quarterly report",
    "project proposal", "budget review", "team meeting agenda",
    "flight confirmation", "hotel reservation", "rental car booking",
    "invoice number", "tracking number", "order confirmation",
    "customer support ticket", "bug report", "feature request",
    "pull request title", "commit message", "branch name",
    "file name", "folder name", "directory path",
    "ip address", "port number", "api key", "access token",
    "username", "password", "email subject", "email body",
    "message text", "chat message", "slack message",
    "discord message", "tweet", "post caption",
    "search query", "google search", "youtube search",
    "amazon search", "wikipedia search", "spotify search",
]

KEY_SHORTCUTS = [
    "press command s to save", "press cmd s", "press cmd s to save",
    "save with the keyboard shortcut", "press escape", "press esc",
    "hit enter", "press return", "press cmd q", "press cmd q to quit",
    "quit the app with cmd q", "press cmd c to copy", "press cmd c",
    "press cmd v to paste", "press cmd v", "press cmd x to cut",
    "press cmd x", "press cmd z to undo", "press cmd z",
    "press cmd shift z to redo", "press cmd a to select all",
    "select all with cmd a", "press cmd f to find", "press cmd f",
    "press cmd g to find next", "press cmd shift g",
    "press cmd w to close tab", "press cmd w",
    "press cmd t for new tab", "press cmd t",
    "press cmd n for new window", "press cmd n",
    "press cmd shift n", "press cmd o to open",
    "press cmd p to print", "press cmd p",
    "press cmd r to refresh", "press cmd r",
    "press cmd shift r for hard refresh", "press cmd shift r",
    "press cmd plus to zoom in", "press cmd minus to zoom out",
    "press cmd 0 to reset zoom", "press cmd tab to switch apps",
    "press cmd space for spotlight", "press cmd space",
    "press cmd shift 3 for screenshot", "press cmd shift 4 for selection screenshot",
    "press cmd shift 5 for screen recording",
    "press cmd control q to lock screen",
    "press cmd option esc to force quit",
    "press fn f to toggle fullscreen", "press control f to fullscreen",
    "press tab to move to next field", "press shift tab",
    "press space to scroll down", "press arrow down",
    "press arrow up", "press arrow left", "press arrow right",
    "press page down", "press page up",
    "press home to go to top", "press end to go to bottom",
]

SCROLL_REQUESTS = [
    "scroll down a bit", "scroll up a bit", "scroll down",
    "scroll up", "scroll to the top", "scroll to the bottom",
    "scroll to the top of the page", "scroll to the bottom of the page",
    "page down", "page up", "scroll down five lines",
    "scroll up three lines", "scroll down two pages",
    "scroll up one page", "scroll left", "scroll right",
    "scroll to the end", "scroll to the beginning",
    "scroll back up", "scroll back down", "keep scrolling down",
    "scroll a little more", "scroll down a lot",
    "scroll up a little", "scroll down slowly",
    "scroll to the comments", "scroll to the top please",
    "scroll past the ads", "scroll to the next section",
    "scroll to the search results", "scroll to the bottom of the list",
]

# --- App opening ---

APPS = [
    "safari", "mail", "calendar", "notes", "reminders", "messages",
    "music", "spotify", "youtube", "finder", "settings", "photos",
    "maps", "facetime", "slack", "vs code", "terminal", "xcode",
    "chrome", "firefox", "notion", "figma", "pages", "numbers",
    "keynote", "imovie", "garageband", "preview", "textedit",
    "whatsapp", "telegram", "discord", "zoom", "teams",
    "app store", "system settings", "activity monitor",
    "calculator", "weather", "stocks", "clock", "voice memos",
    "quicktime player", "books", "podcasts", "tv", "news",
    "reminders app", "calendar app", "notes app",
]

URLS = [
    "youtube.com", "google.com", "github.com", "stackoverflow.com",
    "reddit.com", "twitter.com", "x.com", "linkedin.com",
    "facebook.com", "instagram.com", "tiktok.com",
    "amazon.com", "wikipedia.org", "medium.com", "dev.to",
    "hacker news", "product hunt", "arxiv.org",
    "netflix.com", "spotify.com", "apple.com",
    "gmail.com", "outlook.com", "protonmail.com",
    "dropbox.com", "google drive", "icloud.com",
    "notion.so", "figma.com", "linear.app", "vercel.com",
    "netlify.com", "cloudflare.com", "aws.amazon.com",
    "openai.com", "anthropic.com", "huggingface.co",
    "colab.research.google.com", "replit.com",
    "my bank website", "my email", "my calendar",
    "the new york times", "the wall street journal",
    "the verge", "techcrunch", "ars technica",
]

# --- Media control ---

MEDIA_ACTIONS = [
    "play music", "pause music", "play", "pause",
    "next track", "next song", "previous track", "previous song",
    "skip this song", "skip", "shuffle my music", "shuffle",
    "repeat this song", "repeat", "stop the music",
    "play my playlist", "play my favorites", "play my liked songs",
    "play my most played playlist", "play my favorite playlist",
    "play my chill playlist", "play my workout playlist",
    "play my focus playlist", "play my driving playlist",
    "play something calm", "play something upbeat",
    "play something i'd like", "play some jazz", "play some classical",
    "play some lofi", "play some rock", "play some pop",
    "play some hip hop", "play some electronic", "play some ambient",
    "play the newest album from my favorite artist",
    "play the top songs this week",
    "play music for studying", "play music for working out",
    "play music for sleeping", "play music for focusing",
    "play music for relaxing", "play music for cooking",
    "play music for a party", "play music for a road trip",
]

VOLUME_ACTIONS = [
    "volume up", "volume down", "turn volume up", "turn volume down",
    "increase volume", "decrease volume", "raise volume", "lower volume",
    "reduce volume", "turn it up", "turn it down",
    "mute", "unmute", "mute the volume", "unmute the volume",
    "set volume to 50 percent", "set volume to 30 percent",
    "set volume to 70 percent", "set volume to max",
    "set volume to minimum", "volume up by 2", "volume down by 3",
    "make it louder", "make it quieter", "make it louder please",
    "turn it up a bit", "turn it down a bit",
    "turn it up a lot", "turn it down a lot",
]

BRIGHTNESS_ACTIONS = [
    "brightness up", "brightness down", "turn brightness up",
    "turn brightness down", "increase brightness", "decrease brightness",
    "dim the screen", "brighten the screen", "dim it a bit",
    "brighten it a bit", "dim the screen a lot", "brighten the screen a lot",
    "set brightness to 50 percent", "set brightness to 80 percent",
    "set brightness to 30 percent", "set brightness to max",
    "set brightness to minimum", "make the screen brighter",
    "make the screen darker", "make it brighter", "make it darker",
    "turn down the brightness", "turn up the brightness",
    "reduce brightness", "raise brightness",
]

# --- Calendar / Reminders / Notes ---

CALENDAR_READS = [
    "what's on my calendar", "what is on my calendar",
    "what's on my calendar today", "what's on my calendar tomorrow",
    "what's on my calendar this week", "what's on my calendar next week",
    "check my calendar", "read my calendar", "check calendar",
    "what do i have today", "what do i have tomorrow",
    "what meetings do i have today", "what meetings do i have tomorrow",
    "do i have any meetings today", "do i have any meetings tomorrow",
    "what's my schedule today", "what's my schedule tomorrow",
    "what's my schedule for the week", "show me my calendar",
    "show me today's events", "show me tomorrow's events",
    "what time is my next meeting", "when is my next meeting",
    "how many meetings do i have today",
    "do i have anything on friday", "do i have anything this weekend",
    "what's coming up on my calendar",
]

CALENDAR_CREATE = [
    "create a calendar event for {date} at {time} called {title}",
    "add an event to my calendar for {date} at {time} called {title}",
    "schedule {title} for {date} at {time}",
    "put {title} on my calendar for {date} at {time}",
    "create a meeting called {title} on {date} from {start} to {end}",
    "block off {date} from {start} to {end} for {title}",
    "add a recurring event every {recur} at {time} called {title}",
    "schedule a dentist appointment for {date} at {time}",
    "set up a team meeting for {date} at {time}",
    "create a lunch event with {person} on {date} at {time}",
    "add a deadline for {title} on {date}",
    "schedule a call with {person} for {date} at {time}",
    "book a meeting room for {date} at {time}",
    "set up a zoom meeting for {date} at {time} called {title}",
]

REMINDER_CREATE = [
    "remind me to {action} {when}",
    "create a reminder to {action} {when}",
    "add a reminder to {action} {when}",
    "set a reminder for {when} to {action}",
    "remind me {when} to {action}",
    "don't let me forget to {action} {when}",
    "make sure i remember to {action} {when}",
    "set an alarm to {action} {when}",
    "add a task to {action} {when}",
    "remind me about {action} {when}",
]

NOTE_CREATE = [
    "create a note called {title}",
    "make a note called {title}",
    "create a new note called {title}",
    "open notes and create a note called {title}",
    "start a new note called {title}",
    "jot down a note called {title}",
    "create a note with the title {title}",
    "make a new note titled {title}",
]

# --- Mail / Messages ---

MAIL_CREATE = [
    "compose an email to {person} about {subject}",
    "draft an email to {person} about {subject}",
    "write an email to {person} about {subject}",
    "send an email to {person} about {subject}",
    "compose a mail to {person} regarding {subject}",
    "draft a reply to {person} about {subject}",
    "create a new email to {person} with subject {subject}",
    "email {person} about {subject}",
    "send {person} an email about {subject}",
    "write a message to {person} about {subject}",
]

MESSAGE_CREATE = [
    "send a message to {person} saying {content}",
    "text {person} that {content}",
    "message {person} saying {content}",
    "tell {person} that {content}",
    "send {person} a text saying {content}",
    "text {person} {content}",
    "message {person} {content}",
    "send a message to {person} {content}",
    "let {person} know that {content}",
    "reply to {person} saying {content}",
]

# --- Finder ---

FINDER_ACTIONS = [
    "open finder", "show in finder", "reveal in finder",
    "show this in finder", "reveal this file in finder",
    "open the downloads folder", "open the documents folder",
    "open the desktop folder", "open the applications folder",
    "open my home folder", "open the downloads",
    "open the documents", "go to my downloads",
    "go to my documents", "go to my desktop",
    "show me my downloads", "show me my documents",
    "show me my desktop", "show me my recent files",
    "open the trash", "empty the trash",
    "create a new folder", "make a new folder",
    "create a new folder called {name}",
    "make a new folder called {name}",
    "rename this file to {name}", "rename this folder to {name}",
    "move this to the trash", "move this to trash",
    "duplicate this file", "copy this file to the desktop",
    "copy this to documents", "move this to downloads",
    "compress this folder", "zip this folder",
    "create a zip of this folder",
]

# --- Window management ---

WINDOW_ACTIONS = [
    "minimize this window", "minimize the window",
    "close this window", "close the window",
    "close this tab", "close all tabs",
    "open a new window", "open a new tab",
    "go to the next tab", "go to the previous tab",
    "go to the first tab", "go to the last tab",
    "switch to the next window", "switch to the previous window",
    "go full screen", "enter full screen",
    "exit full screen", "toggle full screen",
    "snap this window to the left", "snap this window to the right",
    "snap this window to the top", "tile this window to the left",
    "tile this window to the right", "split screen with left and right",
    "make this window bigger", "make this window smaller",
    "maximize this window", "restore this window",
    "bring this window to the front", "focus this window",
    "center this window on screen",
    "arrange windows side by side", "tile all windows",
]

# --- Personal assistant parameter pools ---

DATES = [
    "tomorrow", "today", "tonight", "this afternoon",
    "next monday", "next tuesday", "next wednesday", "next thursday",
    "next friday", "next saturday", "next sunday",
    "this monday", "this tuesday", "this friday",
    "next week", "this weekend", "in two days", "in three days",
    "in a week", "in two weeks", "next month",
    "monday", "tuesday", "wednesday", "thursday", "friday",
    "saturday", "sunday",
    "the 15th", "the 20th", "the 25th", "the 30th",
    "march 15th", "april 20th", "may 25th", "june 30th",
    "july 4th", "december 25th", "january 1st",
]

TIMES = [
    "9 am", "10 am", "11 am", "noon", "1 pm", "2 pm", "3 pm",
    "4 pm", "5 pm", "6 pm", "7 pm", "8 pm", "9 pm",
    "9:00 am", "10:30 am", "11:00 am", "12:00 pm",
    "1:30 pm", "2:00 pm", "2:30 pm", "3:00 pm", "3:30 pm",
    "4:00 pm", "4:30 pm", "5:00 pm", "5:30 pm",
    "6:00 pm", "7:00 pm", "8:00 pm",
    "morning", "afternoon", "evening",
]

TIME_RANGES_START = [
    "9 am", "10 am", "11 am", "1 pm", "2 pm", "3 pm",
]

TIME_RANGES_END = [
    "10 am", "11 am", "noon", "2 pm", "3 pm", "4 pm",
    "5 pm", "6 pm",
]

RECUR = [
    "monday", "tuesday", "wednesday", "thursday", "friday",
    "week", "month", "day",
]

PEOPLE = [
    "sarah", "john", "mom", "dad", "mary", "alex", "emma",
    "james", "kate", "mike", "lisa", "tom", "anna", "dave",
    "jen", "chris", "nick", "amy", "ryan", "lauren",
    "the team", "my boss", "my manager", "my assistant",
    "everyone", "the client", "the doctor", "the dentist",
    "the landlord", "the plumber", "the electrician",
    "my wife", "my husband", "my partner", "my sister",
    "my brother", "my son", "my daughter", "my friend",
    "my colleague", "my intern", "my co founder",
    "grandma", "grandpa", "aunt lisa", "uncle bob",
    "rachel", "daniel", "olivia", "ethan", "ava", "noah",
    "sophia", "liam", "mia", "lucas", "zoe", "leo",
    "nora", "henry", "ivy", "owen", "ella", "max",
    "lily", "theo", "ruby", "finn", "hazel", "jude",
    "stella", "miles", "nina", "oscar", "willow", "hugo",
    "the hr department", "the finance team", "the design team",
    "the engineering team", "the marketing team", "the sales team",
    "the legal team", "the support team", "the product team",
    "my therapist", "my lawyer", "my accountant", "my agent",
    "the contractor", "the cleaner", "the babysitter",
    "the vet", "the mechanic", "the barber", "the tailor",
]

REMINDER_ACTIONS = [
    "pick up the kids", "pick up groceries", "call mom",
    "call the doctor", "pay the bills", "submit the report",
    "send the email", "reply to sarah", "schedule the meeting",
    "book the flight", "renew my subscription", "cancel the gym",
    "take out the trash", "do the laundry", "water the plants",
    "feed the cat", "feed the dog", "walk the dog",
    "pick up dry cleaning", "return the library book",
    "renew my driver's license", "schedule an oil change",
    "call the bank", "cancel the reservation",
    "file my taxes", "pay rent", "transfer money",
    "buy a birthday gift", "send a thank you card",
    "check my email", "review the pull request",
    "merge the branch", "deploy the fix", "write the docs",
    "call the dentist", "book a haircut", "renew my passport",
    "schedule a checkup", "refill my prescription",
    "call grandma", "send mom flowers", "plan the trip",
    "book the hotel", "reserve the table", "order the cake",
    "buy groceries", "meal prep for the week", "gym workout",
    "call the school", "sign the permission slip",
    "pay the electric bill", "pay the water bill",
    "cancel the subscription", "update my resume",
    "apply for the job", "follow up on the application",
    "send the invoice", "pay the invoice", "reconcile the accounts",
    "back up my computer", "update my software",
    "change the batteries", "replace the lightbulb",
    "fix the leaky faucet", "schedule pest control",
    "renew my car registration", "get an oil change",
    "rotate my tires", "renew my insurance",
    "call the airline", "check in for my flight",
    "pack for the trip", "print the boarding pass",
    "charge my laptop", "back up my phone",
    "clear my downloads", "empty the trash",
    "respond to the slack message", "close the jira ticket",
    "update the spreadsheet", "finish the presentation",
    "review the contract", "sign the document",
    "notarize the form", "mail the letter",
    "drop off the donation", "pick up the package",
    "wrap the gift", "write the card", "address the envelope",
]

REMINDER_WHENS = [
    "in 10 minutes", "in 30 minutes", "in an hour", "in 2 hours",
    "tomorrow morning", "tomorrow afternoon", "tomorrow at 9 am",
    "tomorrow at 3 pm", "tonight at 8 pm", "tonight",
    "this afternoon", "this evening", "at 5 pm",
    "when i get home", "when i leave work",
    "next monday", "next friday", "in a week",
    "in 15 minutes", "in 45 minutes", "in 90 minutes",
    "in 3 hours", "in 4 hours", "in 6 hours",
    "tomorrow at noon", "tomorrow at 7 am", "tomorrow at 6 pm",
    "tonight at 6 pm", "tonight at 9 pm", "tonight at 10 pm",
    "this morning", "at 9 am", "at 10 am", "at 11 am",
    "at noon", "at 1 pm", "at 2 pm", "at 3 pm", "at 4 pm",
    "at 6 pm", "at 7 pm", "at 8 pm", "at 9 pm",
    "when i wake up", "when i go to bed", "before lunch",
    "after lunch", "before the meeting", "after the meeting",
    "when i arrive", "when i finish", "before i leave",
    "next tuesday", "next wednesday", "next thursday",
    "next saturday", "next sunday", "this weekend",
    "in 2 days", "in 3 days", "in 5 days",
    "in 2 weeks", "in a month", "next month",
    "on my birthday", "on christmas", "on new year's",
]

NOTE_TITLES = [
    "meeting ideas", "shopping list", "todo list", "project notes",
    "brainstorm", "research notes", "meeting agenda",
    "weekly review", "ideas", "reminders",
    "things to do", "books to read", "movies to watch",
    "restaurants to try", "gift ideas", "travel plans",
    "workout plan", "meal plan", "budget notes",
    "code snippets", "interview questions", "learning notes",
    "journal entry", "dream log", "gratitude list",
    "daily standup", "sprint planning", "retro notes",
    "1 on 1 notes", "performance review", "career goals",
    "side project ideas", "startup ideas", "business plan",
    "marketing strategy", "content calendar", "blog post draft",
    "podcast outline", "video script", "presentation outline",
    "lecture notes", "study guide", "flashcards",
    "recipe collection", "cocktail recipes", "wine tasting notes",
    "garden journal", "plant care schedule", "pet care notes",
    "health tracker", "workout log", "running log",
    "reading list", "podcast queue", "watch later",
    "bucket list", "goals 2026", "new year resolutions",
    "holiday plans", "birthday party planning", "event planning",
    "moving checklist", "apartment hunting", "renovation notes",
    "car maintenance log", "home repair todo", "insurance info",
    "password hints", "account recovery codes", "emergency contacts",
    "medical history", "medication schedule", "doctor visits",
    "tax documents", "receipt log", "expense tracker",
    "habit tracker", "mood log", "sleep log",
    "water intake", "calorie log", "weight tracker",
]

MAIL_SUBJECTS = [
    "the quarterly report", "the project update", "the meeting notes",
    "the contract review", "the budget proposal", "the invoice",
    "the presentation", "the agenda", "the status update",
    "the feedback", "the review", "the approval",
    "the schedule change", "the vacation request",
    "the expense report", "the onboarding docs",
    "the code review", "the pull request", "the bug report",
    "the feature request", "the deployment plan",
    "the kickoff agenda", "the roadmap", "the pricing proposal",
    "the nda", "the ms a", "the lease agreement",
    "the offer letter", "the resignation letter",
    "the recommendation letter", "the reference letter",
    "the performance review", "the salary review",
    "the promotion announcement", "the layoff notice",
    "the policy update", "the security alert",
    "the incident report", "the postmortem",
    "the release notes", "the changelog",
    "the user survey", "the customer feedback",
    "the sales forecast", "the pipeline review",
    "the marketing campaign", "the press release",
    "the newsletter", "the event invitation",
    "the webinar invite", "the conference details",
    "the travel itinerary", "the flight confirmation",
    "the hotel booking", "the rental car reservation",
    "the restaurant reservation", "the appointment reminder",
    "the invoice payment", "the receipt", "the refund",
    "the order confirmation", "the shipping update",
    "the delivery notification", "the return label",
    "the warranty info", "the support ticket",
    "the cancellation", "the renewal notice",
    "the subscription update", "the billing statement",
]

MESSAGE_CONTENTS = [
    "i'm running late", "i'm on my way", "i'll be there in 10",
    "i'll be there in 20", "i'm here", "where are you",
    "can we reschedule", "let's push to next week",
    "thanks for the help", "got it thanks", "sounds good",
    "let me check and get back to you", "i'll send it over shortly",
    "just finished the report", "the meeting is confirmed",
    "can you send me the file", "i need the password",
    "what time works for you", "how about tomorrow",
    "i think we should go with option a",
    "the client loved the proposal", "we got the deal",
    "just wrapping up, be home soon", "don't forget dinner tonight",
    "happy birthday", "congrats on the new job",
    "thinking of you", "hope you're feeling better",
    "i miss you", "let's catch up soon",
    "can you call me when you're free",
    "the package arrived", "the delivery is delayed",
    "i left the keys under the mat", "the wifi password is on the fridge",
    "i'm at the coffee shop", "i'm at the airport",
    "my flight landed", "my flight is delayed",
    "i'm boarding now", "i just took off",
    "the meeting went well", "the demo was a hit",
    "we need to talk", "call me when you can",
    "i love you", "goodnight", "good morning",
    "how was your day", "how was the meeting",
    "did you eat yet", "what's for dinner",
    "i'm ordering food", "i'm cooking tonight",
    "let's do dinner friday", "are you free this weekend",
    "i got the promotion", "i quit my job",
    "i'm starting monday", "my last day is friday",
    "the offer is good", "i'm negotiating salary",
    "the interview went great", "they made me an offer",
    "i passed the exam", "i got the results",
    "the doctor said i'm fine", "i need to schedule a follow up",
    "i'm at the gym", "i'm going for a run",
    "i finished the workout", "i hit my step goal",
    "the project is done", "the deploy is live",
    "the build is green", "the tests are passing",
    "i found the bug", "i fixed the issue",
    "the pr is ready for review", "the branch is merged",
    "i'm heading to bed", "i'm waking up now",
    "let's do lunch", "coffee on me",
    "i'm picking up coffee", "i'm at the store",
    "what do you need", "i got the groceries",
    "i forgot the milk", "i'm on my way back",
]

FOLDER_NAMES = [
    "new project", "archive", "backup", "temp", "screenshots",
    "downloads", "reports", "invoices", "contracts",
    "photos 2026", "vacation pics", "work files",
]

FILE_NAMES = [
    "report.pdf", "notes.txt", "data.csv", "config.json",
    "presentation.key", "budget.numbers", "document.pages",
    "screenshot.png", "photo.jpg", "video.mov",
]

# --- Multi-step sequential connectors ---

SEQ_CONNECTORS = [
    " then ", " and then ", " after that ", " next ",
    " once that's done ", " then i need you to ",
    " and after that ", " then go ahead and ",
    " and then also ", " followed by ",
]

# --- Multi-step parallel connectors ---

PAR_CONNECTORS = [
    " and also ", " at the same time ", " while you're at it ",
    " and in parallel ", " and simultaneously ",
    " and also open ", " and ",
]

# --- Search actions ---

SEARCH_ACTIONS = [
    "search for {query}", "google {query}", "look up {query}",
    "search the web for {query}", "find {query} online",
    "search youtube for {query}", "search google for {query}",
    "search wikipedia for {query}", "search amazon for {query}",
    "find me information about {query}",
    "look up {query} on google", "look up {query} on wikipedia",
    "search for {query} on youtube",
]

SEARCH_QUERIES = [
    "how to make pasta", "best restaurants near me",
    "weather tomorrow", "news today", "stock market today",
    "how to tie a tie", "python tutorial", "swift programming",
    "machine learning basics", "react hooks", "docker tutorial",
    "kubernetes guide", "interview tips", "resume template",
    "flight deals", "hotel deals", "car rental deals",
    "recipe for chocolate cake", "how to cook rice",
    "how to change a tire", "how to fix a leaky faucet",
    "best laptop 2026", "best phone 2026", "best headphones",
    "how to invest in stocks", "how to save money",
    "how to meditate", "how to start a business",
    "how to learn a language", "how to play guitar",
    "how to make coffee", "how to bake bread",
    "how to fold a fitted sheet", "how to remove a stain",
    "how to unclog a drain", "how to patch a wall",
    "how to paint a room", "how to hang a picture",
    "how to assemble furniture", "how to wrap a gift",
    "how to write a cover letter", "how to negotiate salary",
    "how to prepare for an interview", "how to network",
    "how to build a website", "how to deploy an app",
    "how to use git", "how to write tests",
    "how to debug javascript", "how to optimize react",
    "how to learn rust", "how to learn typescript",
    "best mechanical keyboards", "best ergonomic mice",
    "best standing desks", "best office chairs",
    "best coffee makers", "best espresso machines",
    "best air fryers", "best instant pots",
    "best vacuum cleaners", "best robot vacuums",
    "best mattresses", "best pillows",
    "best running shoes", "best hiking boots",
    "best yoga mats", "best dumbbells",
    "best coding bootcamps", "best online courses",
    "best programming books", "best ai books",
    "best productivity apps", "best note taking apps",
    "best password managers", "best vpn services",
    "best cloud storage", "best backup solutions",
    "ai news today", "tech news today",
    "apple news today", "google news today",
    "crypto prices today", "bitcoin price",
    "ethereum price", "stock prices today",
    "apple stock price", "google stock price",
    "tesla stock price", "nvidia stock price",
    "mortgage rates today", "cd rates today",
    "high yield savings accounts", "best credit cards",
    "best travel credit cards", "best cash back cards",
    "how to file taxes", "tax deadline 2026",
    "stimulus check status", "refund status",
    "election results", "sports scores today",
    "nba scores", "nfl scores", "mlb scores",
    "premier league results", "world cup schedule",
    "olympics schedule", "super bowl time",
    "movie showtimes near me", "concerts near me",
    "events this weekend", "farmers market near me",
    "parks near me", "hiking trails near me",
    "beaches near me", "camping spots near me",
    "museums near me", "libraries near me",
    "covid testing near me", "urgent care near me",
    "pharmacy near me", "gas station near me",
    "ev charging station near me", "atm near me",
    "dog park near me", "playground near me",
]

NAV_PLACES = [
    "the nearest coffee shop", "the nearest gas station",
    "the nearest hospital", "the nearest pharmacy",
    "the nearest grocery store", "the nearest atm",
    "the nearest restaurant", "the nearest hotel",
    "the airport", "the train station", "the bus stop",
    "home", "work", "the gym", "the post office",
    "the library", "the park", "the beach",
    "123 main street", "the empire state building",
    "central park", "the golden gate bridge",
    "the nearest starbucks", "the nearest mcdonald's",
    "the nearest target", "the nearest walmart",
    "the nearest whole foods", "the nearest trader joe's",
    "the nearest costco", "the nearest apple store",
    "the nearest best buy", "the nearest home depot",
    "the nearest lowes", "the nearest ikea",
    "the nearest urgent care", "the nearest emergency room",
    "the nearest dentist", "the nearest doctor",
    "the nearest vet", "the nearest car wash",
    "the nearest car repair", "the nearest oil change",
    "the nearest car rental", "the nearest bike shop",
    "the nearest bar", "the nearest brewery",
    "the nearest bakery", "the nearest deli",
    "the nearest pizza place", "the nearest sushi restaurant",
    "the nearest taco truck", "the nearest food truck",
    "the nearest park", "the nearest dog park",
    "the nearest playground", "the nearest tennis court",
    "the nearest basketball court", "the nearest swimming pool",
    "the nearest gym", "the nearest yoga studio",
    "the nearest climbing gym", "the nearest golf course",
    "the nearest hiking trail", "the nearest beach",
    "the nearest campsite", "the nearest ski resort",
    "the nearest museum", "the nearest art gallery",
    "the nearest movie theater", "the nearest bowling alley",
    "the nearest arcade", "the nearest escape room",
    "the nearest library", "the nearest community center",
    "the nearest school", "the nearest university",
    "the nearest courthouse", "the nearest dmv",
    "the nearest passport office", "the nearest post office",
    "the nearest bank", "the nearest credit union",
    "the nearest currency exchange", "the nearest notary",
]

# --- Navigation actions ---

NAV_ACTIONS = [
    "navigate to {place}", "give me directions to {place}",
    "open maps and find {place}", "how do i get to {place}",
    "find the nearest {place}", "where is the nearest {place}",
    "show me {place} on the map", "open maps and search for {place}",
]

NAV_PLACES = [
    "the nearest coffee shop", "the nearest gas station",
    "the nearest hospital", "the nearest pharmacy",
    "the nearest grocery store", "the nearest atm",
    "the nearest restaurant", "the nearest hotel",
    "the airport", "the train station", "the bus stop",
    "home", "work", "the gym", "the post office",
    "the library", "the park", "the beach",
    "123 main street", "the empire state building",
    "central park", "the golden gate bridge",
]

# --- Screenshot / file actions ---

SCREENSHOT_ACTIONS = [
    "take a screenshot", "screenshot the screen",
    "capture the screen", "screenshot this window",
    "screenshot the whole screen", "take a screenshot of this",
    "grab a screenshot", "screen capture",
    "take a screenshot and save it to the desktop",
    "screenshot and copy to clipboard",
]

FILE_OPS = [
    "save this file", "save the file", "save as {name}",
    "export as pdf", "export this as pdf",
    "print this document", "print this page", "print this",
    "download this file", "download this",
    "upload this file", "upload this",
    "attach this file", "attach this to the email",
    "open this file", "open this document",
    "delete this file", "delete this",
    "rename this to {name}", "move this to {dest}",
    "copy this to {dest}", "duplicate this",
]

FILE_DESTS = [
    "the desktop", "documents", "downloads", "a new folder",
    "the trash", "an external drive", "icloud",
]

# --- Multi-action personal assistant templates (the complex ones) ---

MULTI_STEP_TEMPLATES = [
    # Sequential: browser → website → play
    "open safari then go to {url} and play the first video",
    "open {browser} then navigate to {url} and search for {query}",
    "open safari go to {url} and click the first result",
    "open chrome then go to {url} and play the video",
    "open safari and go to {url} then scroll down and click play",
    "open the browser then go to youtube and search for {query} and play the first result",
    "open safari then go to {url} and log in with my credentials",
    "open {browser} then go to {url} and download the file",

    # Sequential: app → action → action
    "open mail then find the latest email from {person} and reply saying {content}",
    "open mail and compose a new email to {person} about {subject} then send it",
    "open messages then send a text to {person} saying {content}",
    "open notes and create a new note called {title} then type {content}",
    "open calendar and create an event for {date} at {time} called {title} then set a reminder for 30 minutes before",
    "open reminders and add a reminder to {action} {when}",
    "open {app} then create a new document and type {content}",
    "open finder then go to downloads and open the latest file",
    "open slack then go to the {person} channel and post {content}",
    "open spotify then play my favorite playlist",
    "open music then play my most played songs",
    "open photos then find my latest screenshot and share it with {person}",
    "open maps then search for {place} and start navigation",
    "open safari then search for {query} and open the first result",
    "open terminal then run the build command and show me the output",
    "open vs code then open the project folder and start the dev server",
    "open calendar then check what meetings i have {date} and add a new one if there's a gap",

    # Sequential: screenshot → share
    "take a screenshot then open messages and send it to {person}",
    "take a screenshot then open mail and attach it to an email to {person}",
    "take a screenshot then save it to the desktop",
    "take a screenshot then copy it and paste it into notes",

    # Sequential: create → share
    "create a note called {title} then share it with {person}",
    "create a calendar event for {date} at {time} called {title} then invite {person}",
    "write an email to {person} about {subject} then attach the latest file from downloads",
    "compose a message to {person} saying {content} then send it",

    # Sequential: search → act
    "search for {query} then open the first result",
    "search youtube for {query} then play the first video",
    "search google for {query} then click the top result",
    "search for {query} on amazon then add the first item to cart",
    "search for {query} then copy the first result and paste it into notes",

    # Sequential: file ops
    "open finder then go to documents and find the file called {name} then email it to {person}",
    "open the downloads folder then move the latest file to documents",
    "open finder then find {name} and move it to {dest}",

    # Sequential: multi-app
    "open safari and go to {url} then take a screenshot and send it to {person} via messages",
    "open mail and read the latest email from {person} then create a reminder to reply {when}",
    "open calendar and check my schedule {date} then open notes and write down my agenda",
    "open spotify and play my focus playlist then open vs code and start coding",
    "open slack and check my messages then open mail and reply to the latest email",

    # Parallel: multiple apps at once
    "open mail and calendar at the same time",
    "open safari and notes side by side",
    "open slack and messages at the same time",
    "open mail and messages simultaneously",
    "open both slack and email please",
    "open safari and terminal at the same time",
    "split the screen with safari on the left and notes on the right",
    "open vs code and terminal side by side",
    "open calendar and reminders at the same time",
    "open mail and slack side by side",
    "open spotify and vs code at the same time",
    "open both notepad and calculator",
    "open finder and terminal simultaneously",
    "open chrome and vs code side by side",
    "open messages and mail at the same time",

    # Parameterized personal assistant
    "play my favorite playlist",
    "play my most played playlist",
    "play my most played songs",
    "play my liked songs",
    "play the song i was listening to yesterday",
    "play something i'd like based on my taste",
    "play my daily mix",
    "play my discover weekly",
    "play my release radar",
    "play my on repeat playlist",
    "play my repeat playlist",
    "play my recently added songs",
    "play the top songs in my library",
    "play my morning routine playlist",
    "play my evening chill playlist",
    "play my running playlist",
    "play my coding playlist",
    "play my study playlist",
    "play my commute playlist",
    "play my dinner playlist",
    "play music based on what i usually listen to",
    "play something similar to what i was just listening to",

    "text {person} that i'm running late",
    "text {person} that i'm on my way",
    "text {person} that i'll be 15 minutes late",
    "text {person} that i got home safe",
    "text {person} to remind them about {subject}",
    "text my wife i'm on my way home",
    "text my husband i'm leaving now",
    "text mom that i'll call her tonight",
    "text the team that the meeting is moved to {time}",
    "text {person} happy birthday",
    "text {person} congrats on the new job",

    "email {person} the {subject}",
    "email the team the {subject}",
    "email my boss the {subject}",
    "email {person} a copy of the {subject}",
    "forward the latest email from {person} to {person2}",
    "reply to {person}'s email saying {content}",
    "reply all saying {content}",
    "send {person} the file from my downloads",
    "email {person} the screenshot i just took",

    "set a reminder for {when} to {action}",
    "remind me to {action} when i get home",
    "remind me to {action} when i leave work",
    "remind me to {action} {when}",
    "remind me about {person}'s birthday",
    "remind me to call {person} {when}",
    "set a daily reminder to {action}",
    "set a weekly reminder to {action} every {recur}",

    "create a calendar event for {date} at {time} called {title}",
    "schedule a meeting with {person} for {date} at {time}",
    "block off {date} from {start} to {end} for {title}",
    "add a recurring meeting every {recur} at {time} called {title}",
    "reschedule my meeting with {person} to {date} at {time}",
    "cancel my meeting with {person} on {date}",

    "find the email from {person} about {subject}",
    "find the message from {person} about {subject}",
    "find the file called {name} on my computer",
    "find the latest screenshot",
    "find the document i was working on yesterday",
    "find the photo i took {when}",
    "find the contact info for {person}",

    "navigate to {place}",
    "give me directions to {place}",
    "how long will it take to get to {place}",
    "what's the traffic like to {place}",
    "find the nearest {place}",

    "turn down the brightness and turn up the volume",
    "turn up the brightness and mute the volume",
    "dim the screen and play some calm music",
    "set the volume to 30 percent and play my focus playlist",

    # Complex multi-step with parameters
    "open safari then go to {url} and search for {query} then click the first result and take a screenshot",
    "open mail then find the email from {person} about {subject} and forward it to {person2}",
    "open calendar then create an event for {date} at {time} called {title} and set a reminder for 30 minutes before and invite {person}",
    "open notes then create a note called {title} and type {content} then share it with {person}",
    "open spotify then play my favorite playlist and also open vs code and start a new project",
    "take a screenshot then open mail and compose an email to {person} about {subject} and attach the screenshot and send it",
    "open safari and go to {url} then download the file and move it to documents and open it",
    "open messages then send a text to {person} saying {content} then also send the same to {person2}",
    "open finder then find the file called {name} then email it to {person} and also upload it to the cloud",
    "open reminders then add a reminder to {action} {when} and also add another one to {action2} {when2}",

    # 3+ step sequences — browser workflows
    "open safari then go to {url} then log in then navigate to my dashboard and take a screenshot",
    "open {browser} then go to {url} then search for {query} then open the first result and bookmark it",
    "open safari then go to {url} then scroll down to the comments then read the top comment and take a screenshot",
    "open chrome then go to {url} then click the download button then save the file to downloads and open it",
    "open safari then go to {url} then fill in the form with my details and submit it",
    "open {browser} then navigate to {url} then click sign in then enter my credentials and log in",
    "open safari then go to {url} then add the item to my cart then go to checkout and complete the purchase",
    "open safari then go to {url} then find the search bar then type {query} and press enter",
    "open chrome then go to {url} then click the play button then make it full screen and turn up the volume",
    "open safari then go to {url} then find the article then copy the text and paste it into notes",
    "open {browser} then go to {url} then download the file then move it to documents and rename it to {name}",
    "open safari then go to {url} then log in then go to settings then change my password and save",
    "open chrome then go to {url} then scroll to the bottom then click the contact link and send a message",
    "open safari then go to {url} then find the subscribe button then enter my email and confirm",

    # 3+ step sequences — communication workflows
    "open mail then find the latest email from {person} then reply with {content} then attach the file from downloads and send it",
    "open messages then start a new conversation with {person} then type {content} then attach the latest screenshot and send it",
    "open mail then compose a new email to {person} about {subject} then attach the file called {name} then send it and set a reminder to follow up {when}",
    "open slack then go to the {person} channel then post {content} then also share the latest file from downloads",
    "open mail then read the latest email then forward it to {person2} then create a reminder to reply {when}",
    "open messages then send a text to {person} saying {content} then send the same to {person2} then send a third one to {person} saying i'll call later",
    "open mail then find the email from {person} about {subject} then reply saying {content} then archive the original",
    "open messages then find the conversation with {person} then scroll up to the last message then copy it and paste it into notes",
    "open mail then compose an email to {person} then attach the screenshot i just took then also attach the file from downloads and send it",
    "open slack then check my mentions then reply to each one then mark them all as read",

    # 3+ step sequences — calendar/scheduling workflows
    "open calendar then check my schedule for {date} then find a free slot then create a meeting with {person} and send the invite",
    "open calendar then create an event for {date} at {time} called {title} then set a reminder for 30 minutes before then also set one for 1 hour before and invite {person}",
    "open calendar then find my meeting with {person} on {date} then reschedule it to {date} at {time} then notify all attendees",
    "open calendar then check what meetings i have {date} then open notes and create a note called {title} with my agenda then share it with {person}",
    "open calendar then create a recurring meeting every {recur} at {time} called {title} then invite {person} and set a reminder for 15 minutes before",
    "open calendar then check tomorrow's schedule then open reminders and add a reminder to prepare for each meeting",
    "open calendar then find the gap in my schedule {date} then create a focus block from {start} to {end} called deep work and set do not disturb",

    # 3+ step sequences — file/document workflows
    "open finder then go to documents then find the file called {name} then move it to {dest} then email it to {person}",
    "open finder then go to downloads then sort by date then find the latest file then move it to documents and rename it to {name}",
    "open finder then find the file called {name} then duplicate it then rename the copy to {name} then move the original to the trash",
    "open finder then go to documents then select all the files then compress them into a zip then email the zip to {person}",
    "open finder then find the folder called {name} then create a new folder inside it called archive then move all the files into the archive",
    "open finder then go to downloads then find the latest screenshot then rename it to {name} then move it to documents and open it",
    "open finder then find the file called {name} then copy it to the desktop then also copy it to documents then also upload it to the cloud",
    "open finder then go to documents then find the file called {name} then open it then take a screenshot and email it to {person}",

    # 3+ step sequences — creative/content workflows
    "open notes then create a new note called {title} then type {content} then format it then share it with {person}",
    "open notes then create a note called {title} then type my meeting notes then create a checklist then share it with the team",
    "open photos then find my latest screenshots then select the best one then share it with {person} via messages and also email it to {person2}",
    "open photos then find the album called {name} then select the latest 5 photos then share them with {person}",
    "open music then find my favorite playlist then shuffle it then turn up the volume and also open notes so i can jot down ideas",
    "open spotify then play my focus playlist then open vs code then open the project folder and start coding",
    "open garageband then create a new project then record a voice memo then save it to documents and name it {name}",
    "open imovie then create a new project then import the latest video from downloads then trim the first 10 seconds and export it",

    # 3+ step sequences — system/device workflows
    "take a screenshot then copy it to clipboard then open notes then paste it and save the note called {title}",
    "take a screenshot then open mail then compose an email to {person} about {subject} then attach the screenshot and send it",
    "take a screenshot then open messages then send it to {person} then also send it to {person2}",
    "open safari then go to {url} then take a screenshot then open mail and send it to {person}",
    "turn down the brightness then turn up the volume then play my favorite playlist and open vs code",
    "set the volume to 30 percent then set the brightness to 50 percent then play my focus playlist and open notes",
    "mute the volume then dim the screen then open notes and create a note called {title}",
    "turn on do not disturb then close all notifications then open vs code and start coding",

    # 3+ step sequences — research/lookup workflows
    "search for {query} then open the first result then take a screenshot then email it to {person}",
    "search google for {query} then open the first result then copy the text then paste it into a note called {title}",
    "search youtube for {query} then play the first video then turn up the volume and make it full screen",
    "search for {query} on wikipedia then copy the first paragraph then paste it into notes and save it",
    "search for {query} then find the answer then create a note called {title} and type the answer",
    "open safari then search for {query} then open the first result then bookmark it and take a screenshot",

    # Parallel + sequential combinations
    "open safari and notes side by side then go to {url} in safari and take notes in the notes window",
    "open mail and calendar at the same time then check my schedule then reply to the latest email",
    "open vs code and terminal side by side then run the build command in terminal and fix the errors in vs code",
    "open slack and mail simultaneously then check both then reply to the most urgent one",
    "open safari and finder at the same time then download a file from {url} and move it to documents",
    "open messages and mail side by side then send a quick text to {person} then compose a longer email to {person2}",

    # Rich personal-assistant parameterized queries
    "play my favorite playlist and turn the volume up to 60 percent",
    "play my most played songs and open vs code at the same time",
    "play something calm and dim the screen to 30 percent",
    "play my coding playlist then open vs code and start a new project",
    "play my morning playlist and check my calendar for today",
    "play my focus playlist and set do not disturb and open vs code",
    "play my recently played and turn down the brightness",
    "play my liked songs and also set a reminder to {action} {when}",
    "play my discover weekly and open notes so i can jot down ideas",
    "play my daily mix and check my messages at the same time",

    "text {person} that i'm running late then also text {person2} the same thing",
    "text {person} i'll be there in 15 minutes then set a reminder to leave in 10 minutes",
    "text {person} happy birthday then also send them a calendar invite for coffee {date}",
    "text the team that the meeting is moved to {time} then create a new calendar event for {time} called {title}",
    "text {person} the file is ready then email them the file from my downloads",
    "text {person} i got home safe then set a reminder to call them {when}",
    "text {person} congrats on the new job then add a reminder to send a gift {when}",

    "email {person} the {subject} then also forward it to {person2}",
    "email the team the {subject} then create a reminder to follow up {when}",
    "email {person} the latest file from downloads then also send them a message saying it's on the way",
    "email my boss the {subject} then set a reminder to review it {when}",
    "email {person} the screenshot i just took then also attach the file from documents",
    "reply to {person}'s email with {content} then archive the email then create a reminder to follow up {when}",

    "set a reminder to {action} {when} then also add it to my calendar as an event",
    "remind me to {action} {when} then also remind me to {action2} {when2}",
    "remind me to {action} when i get home then also text {person} that i'm on my way",
    "set a daily reminder to {action} then set a weekly reminder to {action2} every {recur}",
    "remind me about {person}'s birthday then create a calendar event for it and set a reminder 3 days before",

    "create a calendar event for {date} at {time} called {title} then invite {person} and {person2} and set a reminder for 1 hour before",
    "schedule a meeting with {person} for {date} at {time} then create an agenda in notes and share it with them",
    "block off {date} from {start} to {end} for {title} then set do not disturb and create a reminder 10 minutes before",
    "reschedule my meeting with {person} to {date} at {time} then notify them via messages and update the calendar invite",

    "find the email from {person} about {subject} then forward it to {person2} and create a reminder to follow up",
    "find the file called {name} then email it to {person} and also upload it to the cloud",
    "find the latest screenshot then send it to {person} via messages and also save it to documents",
    "find the contact info for {person} then call them then send a follow up text saying {content}",

    "navigate to {place} then start navigation then text {person} my eta",
    "give me directions to {place} then start navigation and play my driving playlist",
    "find the nearest {place} then navigate there then text {person} that i'm on my way",
    "search for {place} on maps then start navigation then set a reminder to {action} when i arrive",

    # Workflow combos — multi-app orchestration
    "open mail and check for anything urgent then open calendar and review today's schedule then open slack and check my mentions",
    "open safari and go to {url} then take a screenshot then open mail and compose an email to {person} then attach the screenshot and send it",
    "open notes and create a note called {title} then open safari and search for {query} then copy the results and paste them into the note",
    "open calendar and check my schedule then open notes and write down my priorities then open reminders and add tasks for each one",
    "open spotify and play my focus playlist then open vs code and start coding then set do not disturb and mute notifications",
    "open finder and find the file called {name} then open mail and compose an email to {person} then attach the file and send it",
    "open messages and check for anything urgent then open mail and reply to the latest email then open calendar and check tomorrow's schedule",
    "open safari and go to {url} then download the file then open finder and move it to documents then open the file",
    "open reminders and review my tasks then open calendar and block time for each one then open notes and write down my plan",
    "open slack and check my channels then open mail and reply to urgent emails then open calendar and prepare for my next meeting",
]

BROWSERS = ["safari", "chrome", "firefox", "the browser", "my browser"]

# Additional action2/when2 for complex multi-step
REMINDER_ACTIONS_2 = REMINDER_ACTIONS  # reuse
REMINDER_WHENS_2 = REMINDER_WHENS  # reuse


def fill_template(template: str, rng: random.Random) -> str:
    """Fill in {placeholder} tokens in a template with random values."""
    result = template
    # Simple placeholder replacement
    replacements = {
        "{date}": lambda: rng.choice(DATES),
        "{time}": lambda: rng.choice(TIMES),
        "{start}": lambda: rng.choice(TIME_RANGES_START),
        "{end}": lambda: rng.choice(TIME_RANGES_END),
        "{recur}": lambda: rng.choice(RECUR),
        "{title}": lambda: rng.choice(NOTE_TITLES + MAIL_SUBJECTS),
        "{person}": lambda: rng.choice(PEOPLE),
        "{person2}": lambda: rng.choice(PEOPLE),
        "{subject}": lambda: rng.choice(MAIL_SUBJECTS),
        "{content}": lambda: rng.choice(MESSAGE_CONTENTS),
        "{action}": lambda: rng.choice(REMINDER_ACTIONS),
        "{action2}": lambda: rng.choice(REMINDER_ACTIONS_2),
        "{when}": lambda: rng.choice(REMINDER_WHENS),
        "{when2}": lambda: rng.choice(REMINDER_WHENS_2),
        "{name}": lambda: rng.choice(FOLDER_NAMES + FILE_NAMES),
        "{dest}": lambda: rng.choice(FILE_DESTS),
        "{query}": lambda: rng.choice(SEARCH_QUERIES),
        "{place}": lambda: rng.choice(NAV_PLACES),
        "{url}": lambda: rng.choice(URLS),
        "{browser}": lambda: rng.choice(BROWSERS),
        "{app}": lambda: rng.choice(APPS),
    }
    for placeholder, gen in replacements.items():
        while placeholder in result:
            result = result.replace(placeholder, gen(), 1)
    return result


def build_single_action() -> str:
    """Build a single-action transcript (caller fills variation)."""
    # This is a factory; actual random selection done by caller
    pass


def build_screen_action(count: int, rng: random.Random) -> list[dict]:
    examples = []
    seen = set()
    attempts = 0

    # Weighted distribution of action subtypes
    while len(examples) < count and attempts < count * 20:
        attempts += 1

        category = rng.choices(
            population=[
                "click", "type", "key", "scroll", "open_app",
                "open_url", "media", "volume", "brightness",
                "calendar_read", "calendar_create", "reminder",
                "note", "mail", "message", "finder", "window",
                "search", "nav", "screenshot", "file_ops",
                "multi_step", "personal_assistant",
            ],
            weights=[
                6, 4, 4, 3, 5, 3, 4, 2, 2,
                2, 3, 3, 2, 3, 3, 2, 2,
                3, 2, 2, 2,
                20, 20,
            ],
            k=1,
        )[0]

        base = ""

        if category == "click":
            verb = rng.choice(ACTION_VERBS)
            target = rng.choice(ACTION_TARGETS)
            base = f"{verb} {target}"

        elif category == "type":
            text_to_type = rng.choice(TYPING_TEXTS)
            base = f"type {text_to_type}"

        elif category == "key":
            base = rng.choice(KEY_SHORTCUTS)

        elif category == "scroll":
            base = rng.choice(SCROLL_REQUESTS)

        elif category == "open_app":
            app = rng.choice(APPS)
            verb = rng.choice(["open", "launch", "start", "open the", "launch the"])
            base = f"{verb} {app}"
            # Sometimes add "app" suffix
            if rng.random() < 0.3 and not app.endswith("app"):
                base += " app"

        elif category == "open_url":
            url = rng.choice(URLS)
            verb = rng.choice([
                f"open {url}", f"go to {url}", f"navigate to {url}",
                f"open the website {url}", f"visit {url}",
                f"open {url} in the browser",
                f"open {url} in safari",
            ])
            base = verb

        elif category == "media":
            base = rng.choice(MEDIA_ACTIONS)

        elif category == "volume":
            base = rng.choice(VOLUME_ACTIONS)

        elif category == "brightness":
            base = rng.choice(BRIGHTNESS_ACTIONS)

        elif category == "calendar_read":
            base = rng.choice(CALENDAR_READS)

        elif category == "calendar_create":
            template = rng.choice(CALENDAR_CREATE)
            base = fill_template(template, rng)

        elif category == "reminder":
            template = rng.choice(REMINDER_CREATE)
            base = fill_template(template, rng)

        elif category == "note":
            template = rng.choice(NOTE_CREATE)
            base = fill_template(template, rng)

        elif category == "mail":
            template = rng.choice(MAIL_CREATE)
            base = fill_template(template, rng)

        elif category == "message":
            template = rng.choice(MESSAGE_CREATE)
            base = fill_template(template, rng)

        elif category == "finder":
            template = rng.choice(FINDER_ACTIONS)
            base = fill_template(template, rng)

        elif category == "window":
            base = rng.choice(WINDOW_ACTIONS)

        elif category == "search":
            template = rng.choice(SEARCH_ACTIONS)
            base = fill_template(template, rng)

        elif category == "nav":
            template = rng.choice(NAV_ACTIONS)
            base = fill_template(template, rng)

        elif category == "screenshot":
            base = rng.choice(SCREENSHOT_ACTIONS)

        elif category == "file_ops":
            template = rng.choice(FILE_OPS)
            base = fill_template(template, rng)

        elif category == "multi_step":
            template = rng.choice(MULTI_STEP_TEMPLATES)
            base = fill_template(template, rng)

        elif category == "personal_assistant":
            # Pick from the personal-assistant style templates
            pa_templates = [
                t for t in MULTI_STEP_TEMPLATES
                if "favorite playlist" in t or "most played" in t
                or "text {person}" in t or "email {person}" in t
                or "remind me" in t or "create a calendar" in t
                or "find the" in t or "navigate" in t
                or "play my" in t or "set a reminder" in t
            ]
            template = rng.choice(pa_templates)
            base = fill_template(template, rng)

        if not base:
            continue

        text = apply_variation(base, rng, "screenAction")
        if text in seen:
            continue
        seen.add(text)
        examples.append({"transcript": text, "intent": "screenAction"})

    return examples


# ===========================================================================
# RESEARCH — multi-step research turns
# ===========================================================================

RESEARCH_TOPICS = [
    "the latest ai models", "quantum computing breakthroughs",
    "the state of fusion energy", "crispr gene editing",
    "the electric vehicle market", "space exploration 2026",
    "the semiconductor industry", "climate change solutions",
    "renewable energy trends", "the housing market",
    "inflation and interest rates", "the job market for developers",
    "the best mechanical keyboards", "the latest macbook rumors",
    "vision pro reviews", "the state of web frameworks",
    "rust vs go for systems programming", "the ml ecosystem in 2026",
    "local llm performance", "apple silicon vs nvidia",
    "the future of coding assistants", "ai agent frameworks",
    "the best note-taking apps", "productivity tools 2026",
    "the state of open source", "the creator economy",
    "streaming platform wars", "the gaming industry",
    "the best programming languages to learn", "the ai safety debate",
    "the impact of ai on jobs", "the future of remote work",
    "the state of crypto in 2026", "web3 adoption",
    "the best mechanical keyboard switches", "ergonomic desk setups",
    "the standing desk debate", "the pomodoro technique",
    "deep work strategies", "the getting things done method",
    "the latest research on sleep", "the science of habit formation",
    "the psychology of productivity", "the economics of ai",
    "the cost of training large models", "the open source ai movement",
    "the moe architecture trend", "the distillation techniques landscape",
    "the state of function calling benchmarks", "the bfcl leaderboard",
    "the tau-bench results", "the latest from anthropic",
    "the latest from openai", "the latest from google ai",
    "the latest from meta ai", "the latest from mistral",
    "the latest from deepseek", "the latest from qwen",
]

RESEARCH_PATTERNS = [
    "research {}",
    "do research on {}",
    "do some research on {}",
    "research the {}",
    "deep research {}",
    "look into {}",
    "dig into {}",
    "investigate {}",
    "find sources on {}",
    "find me sources on {}",
    "summarize sources on {}",
    "summarise sources on {}",
    "what's the latest on {}",
    "whats the latest on {}",
    "give me a writeup on {}",
    "give me a write-up on {}",
    "compare {}",
    "{} vs {}",
    "{} versus {}",
    "compare {} and {}",
    "compare {} vs {}",
    "give me a deep dive on {}",
    "do a deep dive on {}",
    "i need a thorough analysis of {}",
    "can you research {} for me",
    "look up the latest on {}",
    "find out what's new with {}",
    "what's the current state of {}",
    "give me an overview of the {} landscape",
    "what are the trends in {}",
    "what's happening in {}",
    "what's going on with {}",
]

COMPARE_TOPICS = [
    "react vs vue", "python vs rust", "docker vs podman",
    "postgres vs mysql", "rest vs graphql", "grpc vs rest",
    "kubernetes vs docker swarm", "vs code vs intellij",
    "macbook vs thinkpad", "apple music vs spotify",
    "notion vs obsidian", "slack vs discord",
    "github vs gitlab", "vercel vs netlify",
    "tailwind vs css modules", "svelte vs react",
    "go vs rust", "typescript vs javascript",
    "claude vs gpt", "local models vs cloud models",
    "lora vs qlora", "sft vs dpo",
    "mlx vs pytorch", "coreml vs metal",
]


def build_research(count: int, rng: random.Random) -> list[dict]:
    examples = []
    seen = set()
    attempts = 0
    while len(examples) < count and attempts < count * 20:
        attempts += 1
        # 60% topic research, 40% comparison
        if rng.random() < 0.60:
            topic = rng.choice(RESEARCH_TOPICS)
            # Only use single-placeholder patterns for topic research
            single_patterns = [p for p in RESEARCH_PATTERNS if p.count("{}") == 1]
            pattern = rng.choice(single_patterns)
            base = pattern.format(topic)
        else:
            compare = rng.choice(COMPARE_TOPICS)
            pattern = rng.choice([
                "compare {}", "compare {} for me", "{} which is better",
                "which is better {}", "{} pros and cons",
                "break down {}", "analyze {}",
            ])
            base = pattern.format(compare)
        text = apply_variation(base, rng, "research")
        if text in seen:
            continue
        seen.add(text)
        examples.append({"transcript": text, "intent": "research"})
    return examples


# ===========================================================================
# PHONE LARGE MODEL — explicit escalation requests
# ===========================================================================

LARGE_MODEL_PATTERNS = [
    "phone a large model",
    "ask the big model",
    "use the big model",
    "use a large model",
    "call the large model",
    "hard mode",
    "think deeply",
    "use a stronger model",
    "phone a friend",
    "ask the big brain",
    "use the big brain",
    "escalate this",
    "this needs the big model",
    "use your strongest model for this",
    "use the most capable model",
    "bring out the big guns",
    "i need the smart model for this",
    "this is too hard for the local model",
    "route this to the large model",
    "use the cloud model for this one",
    "ask the frontier model",
    "use the frontier model",
    "this needs frontier level reasoning",
    "deep think this",
    "think really hard about this",
    "put on your thinking cap",
    "use maximum reasoning",
    "use extended thinking",
    "use the reasoning model",
    "this needs o1 level thinking",
    "this needs deep reasoning",
    "use the powerful model",
    "use the heavy model",
    "switch to the large model",
    "use the big one for this",
]

LARGE_MODEL_CONTEXTS = [
    "", "", "",  # often bare
    " for this question",
    " for this one",
    " for this problem",
    " for this task",
    " to answer this",
    " to solve this",
    " for this complex question",
    " because this is tricky",
    " because this is complicated",
    " i need a really good answer",
    " this is important",
    " don't just give me a quick answer",
]


def build_phone_large_model(count: int, rng: random.Random) -> list[dict]:
    examples = []
    seen = set()
    attempts = 0
    while len(examples) < count and attempts < count * 25:
        attempts += 1
        pattern = rng.choice(LARGE_MODEL_PATTERNS)
        context = rng.choice(LARGE_MODEL_CONTEXTS)
        base = pattern + context
        text = apply_variation(base, rng, "phoneLargeModel")
        if text in seen:
            continue
        seen.add(text)
        examples.append({"transcript": text, "intent": "phoneLargeModel"})
    return examples


# ===========================================================================
# UNKNOWN — adversarial near-misses, ambiguous, out-of-scope
# ===========================================================================

# Out-of-scope: device control, external services, things Pace can't do
OOS_DEVICE = [
    "turn off the lights", "turn on the lights",
    "dim the living room lights", "set the thermostat to 72",
    "lock the front door", "unlock the door",
    "start the robot vacuum", "stop the vacuum",
    "turn on the tv", "turn off the tv",
    "change the tv channel to espn", "change the tv to channel 5",
    "set the apple tv to netflix",
    "turn on the coffee maker", "start the dishwasher",
    "close the garage door", "open the garage door",
    "water the garden", "start the sprinklers",
    "turn on the fan", "turn off the fan",
    "set the bedroom lights to warm white",
    "make the house warmer", "make the house cooler",
    "is the front door locked",
    "what's the temperature inside",
    "what's the humidity in the house",
]

OOS_EXTERNAL = [
    "order a pizza", "order pizza from dominos",
    "order an uber", "call an uber", "book an uber",
    "order an uber eats", "order food from doordash",
    "order groceries from instacart",
    "book a flight to new york", "book a flight to london",
    "book a hotel in paris", "book an airbnb",
    "reserve a table at the italian place",
    "make a restaurant reservation",
    "call a taxi", "call a cab",
    "post a tweet", "post on instagram", "post on tiktok",
    "post on facebook", "post on linkedin",
    "shazam this song", "what song is this",
    "identify this song", "name that tune",
    "order from amazon", "buy this on amazon",
    "add to cart on amazon", "checkout on amazon",
    "send money via venmo", "send money via paypal",
    "pay my credit card", "pay my mortgage",
    "transfer money to savings",
    "buy bitcoin", "sell my stocks", "trade options",
    "book a doctor's appointment",
    "book a haircut", "schedule a car wash",
]

OOS_AMBIGUOUS = [
    # Things that could be multiple intents
    "this", "that", "here", "there", "it", "this one", "that one",
    "yes", "no", "maybe", "sure", "fine", "ok whatever",
    "do it", "go ahead", "continue", "proceed", "next",
    "again", "repeat", "redo", "undo", "never mind",
    "what about that", "what about it", "and that one",
    "the other thing", "you know what i mean",
    "the usual", "the normal one", "the regular",
    "just the basics", "the standard one",
    # Bare nouns without verbs — no clear intent
    "safari", "mail", "calendar", "notes", "messages",
    "the file", "the document", "the email", "the message",
    "the meeting", "the appointment", "the reminder",
    "the project", "the code", "the bug", "the issue",
    "the report", "the spreadsheet", "the presentation",
    "the folder", "the image", "the photo", "the video",
    "the link", "the url", "the website", "the page",
    "the tab", "the window", "the menu", "the button",
    "the form", "the field", "the input", "the text",
    "the password", "the username", "the email address",
    "the phone number", "the address", "the contact",
    # Partial / incomplete sentences
    "i want to", "i need to", "can you", "how about",
    "what if", "is there a way", "is it possible",
    "i was wondering", "do you think", "should i",
    "i'm thinking about", "i'm considering",
    "what would happen if", "what if i",
    "i wonder", "hmm what about",
    # Multi-intent conflicts
    "explain this and then click it",
    "what is this and open it",
    "describe the screen and type hello",
    "read this then research it",
    "summarize this and also play music",
    "explain this and then open it and then research it",
    "describe the screen and then take a screenshot and then email it",
    # Things that sound like actions but aren't actionable
    "i like this", "this is nice", "this looks good",
    "this is broken", "this doesn't work", "this is wrong",
    "why is this here", "what is this doing",
    "i don't like this", "can you fix this",
    "this needs to be better", "this is too slow",
    "this is confusing", "this is hard to use",
    "this is ugly", "this is beautiful",
    "this is interesting", "this is boring",
    "this is too big", "this is too small",
    "this is too loud", "this is too quiet",
    "this is too bright", "this is too dark",
    "i love this", "i hate this",
    "this reminds me of something",
    "this looks familiar", "this looks weird",
    "this doesn't make sense", "this makes no sense",
    # Philosophical / vague
    "what's the meaning of life",
    "why are we here", "what's my purpose",
    "tell me a joke", "sing me a song",
    "write me a poem", "write me a story",
    "be my friend", "are you my friend",
    "what's the point of all this",
    "are we alone in the universe",
    "is there a god", "what happens after death",
    "do we have free will",
    "is the simulation real",
    "are we in the matrix",
    # Time / date questions that aren't calendar reads
    "what time is it", "what's the date",
    "what day is it", "what month is it",
    "what year is it", "is it a leap year",
    "how many days until christmas",
    "how many days until my birthday",
    "how many days in february",
    "what time zone am i in",
    "what's the time difference between here and tokyo",
    # Weather (out of scope for local)
    "what's the weather", "what's the weather like",
    "will it rain today", "is it going to snow",
    "what's the temperature outside",
    "what's the forecast for tomorrow",
    "what's the uv index",
    "what's the air quality",
    "is there a storm coming",
    "how windy is it out there",
    # Math (not a screen action)
    "what's 2 plus 2", "what's 17 times 23",
    "calculate the tip for a 50 dollar bill",
    "what's the square root of 144",
    "what's 15 percent of 80",
    "convert 100 dollars to euros",
    "convert 5 miles to kilometers",
    "convert 100 fahrenheit to celsius",
    "how many ounces in a cup",
    "how many cups in a gallon",
    # Translation (not a screen action)
    "how do you say hello in spanish",
    "translate this to french", "what does bonjour mean",
    "how do you say thank you in japanese",
    "what does gracias mean",
    "translate good morning to german",
    # General advice (not actionable)
    "should i quit my job", "should i buy or rent",
    "what should i eat for dinner", "what should i name my cat",
    "give me advice on", "help me decide",
    "what should i do with my life",
    "should i go back to school",
    "should i move to a new city",
    "should i break up with my partner",
    "should i buy a house",
    "should i get a dog",
    "should i have kids",
    "what's the best way to lose weight",
    "what's the best way to learn coding",
    "what's the best way to save money",
    "how do i deal with stress",
    "how do i overcome procrastination",
    "how do i make friends",
    "how do i be more productive",
    "how do i be more confident",
    # Opinions / preferences (not actionable)
    "do you think ai will replace us",
    "is mac better than windows",
    "is python better than javascript",
    "what's your favorite color",
    "what's your favorite food",
    "do you like music",
    "do you dream",
    "what do you do for fun",
    # Random facts that aren't knowledge questions
    "how tall is the eiffel tower",
    "how deep is the ocean",
    "how far is the moon",
    "how old is the earth",
    "how many people live in tokyo",
    "who won the world series",
    "who won the super bowl",
    "what's the capital of brazil",
    "what's the largest country",
    "what's the smallest country",
]

OOS_NEAR_MISS = [
    # Sounds like an action but the verb is wrong / missing
    "maybe click", "try clicking", "attempt to press",
    "consider opening", "think about typing",
    "would it be possible to",
    "is there a way to",
    "how do i",
    "where is the",
    "which one is the",
    "how many", "how much", "how long",
    "why does", "why is", "why can't",
    "when will", "when did", "when is",
    "who is", "who was", "who made",
    "where is", "where are", "where can i",
    # Commands to other systems
    "hey siri", "ok google", "alexa",
    "hey siri set a timer", "ok google what's the weather",
    "alexa play music", "hey siri call mom",
    "hey siri send a message to john",
    "hey siri what's my battery percentage",
    "ok google navigate home",
    "alexa turn off the lights",
    "hey siri remind me to call mom",
    "ok google set an alarm for 7 am",
    "alexa what's on my shopping list",
    "hey siri play my morning playlist",
    "ok google add milk to my shopping list",
    "alexa read me the news",
    # Things that reference the screen but aren't descriptions or actions
    "is this the right window", "am i in the right app",
    "should i close this", "is this safe to delete",
    "is this the latest version", "is this up to date",
    "is this the right document", "is this the right file",
    "does this look correct", "is this a virus",
    "is this a scam", "is this email legit",
    "should i trust this website",
    "is this a good price", "is this a good deal",
    "is this worth it", "should i buy this",
    # Emotional / exclamations
    "wow", "oh no", "ugh", "damn it",
    "come on", "seriously", "really",
    "you've got to be kidding me",
    "this is amazing", "this is terrible",
    "i can't believe this", "no way",
    "that's crazy", "that's insane",
    "oh my god", "holy cow",
    "what the heck", "what on earth",
    # Off-topic rambling
    "i had the weirdest dream last night",
    "i can't stop thinking about that show",
    "do you ever just stare at the ceiling",
    "i'm so tired today", "i'm so bored",
    "i'm so hungry", "i'm so thirsty",
    "i need a vacation", "i need a break",
    "i need coffee", "i need sleep",
    "i can't focus today", "i'm distracted",
    "i'm in a weird mood", "i feel off today",
]


def build_unknown(count: int, rng: random.Random) -> list[dict]:
    examples = []
    seen = set()
    pool = OOS_DEVICE + OOS_EXTERNAL + OOS_AMBIGUOUS + OOS_NEAR_MISS
    attempts = 0
    while len(examples) < count and attempts < count * 20:
        attempts += 1
        base = rng.choice(pool)
        text = apply_variation(base, rng, "unknown")
        if text in seen:
            continue
        seen.add(text)
        examples.append({"transcript": text, "intent": "unknown"})
    return examples


# ===========================================================================
# MAIN
# ===========================================================================

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="High-variation intent corpus generator for PaceIntentClassifier."
    )
    parser.add_argument(
        "--total", type=int, default=10000,
        help="Target total examples (default 10000).",
    )
    parser.add_argument(
        "--seed", type=int, default=42,
        help="Random seed for reproducibility.",
    )
    parser.add_argument(
        "--out-prefix", type=str, default="synthetic-large",
        help="Output file prefix (default: synthetic-large).",
    )
    parser.add_argument(
        "--split", type=float, default=0.0,
        help="If >0, also write a stratified train/eval split with this eval fraction (e.g. 0.15 = 15%% eval).",
    )
    args = parser.parse_args(argv)

    rng = random.Random(args.seed)
    total = args.total

    # Class distribution (percentages)
    # screenAction is the biggest because it has the most subtypes
    # and the user specifically wants multi-action complexity
    distribution = {
        "chitchat": 0.15,
        "pureKnowledge": 0.20,
        "screenDescription": 0.12,
        "screenAction": 0.40,
        "research": 0.06,
        "phoneLargeModel": 0.03,
        "unknown": 0.04,
    }

    counts = {cls: int(total * pct) for cls, pct in distribution.items()}
    # Adjust for rounding
    counts["screenAction"] += total - sum(counts.values())

    print(f"Generating {total} examples with distribution:")
    for cls, cnt in sorted(counts.items()):
        print(f"  {cls:24s}  {cnt:6d}")
    print()

    all_examples: list[dict] = []

    print("Building chitchat...", end=" ", flush=True)
    examples = build_chitchat(counts["chitchat"], rng)
    print(f"{len(examples)}")
    all_examples.extend(examples)

    print("Building pureKnowledge...", end=" ", flush=True)
    examples = build_pure_knowledge(counts["pureKnowledge"], rng)
    print(f"{len(examples)}")
    all_examples.extend(examples)

    print("Building screenDescription...", end=" ", flush=True)
    examples = build_screen_description(counts["screenDescription"], rng)
    print(f"{len(examples)}")
    all_examples.extend(examples)

    print("Building screenAction...", end=" ", flush=True)
    examples = build_screen_action(counts["screenAction"], rng)
    print(f"{len(examples)}")
    all_examples.extend(examples)

    print("Building research...", end=" ", flush=True)
    examples = build_research(counts["research"], rng)
    print(f"{len(examples)}")
    all_examples.extend(examples)

    print("Building phoneLargeModel...", end=" ", flush=True)
    examples = build_phone_large_model(counts["phoneLargeModel"], rng)
    print(f"{len(examples)}")
    all_examples.extend(examples)

    print("Building unknown...", end=" ", flush=True)
    examples = build_unknown(counts["unknown"], rng)
    print(f"{len(examples)}")
    all_examples.extend(examples)

    # Shuffle
    rng.shuffle(all_examples)

    # Verify uniqueness
    transcripts = [e["transcript"] for e in all_examples]
    unique = len(set(transcripts))
    print(f"\nTotal: {len(all_examples)} examples ({unique} unique)")

    if unique < len(all_examples):
        print(f"WARNING: {len(all_examples) - unique} duplicates detected. Removing...")
        seen = set()
        deduped = []
        for e in all_examples:
            if e["transcript"] not in seen:
                seen.add(e["transcript"])
                deduped.append(e)
        all_examples = deduped
        print(f"After dedup: {len(all_examples)} examples")

    # Write output
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    jsonl_path = OUTPUT_DIR / f"{args.out_prefix}.jsonl"
    with jsonl_path.open("w") as f:
        for example in all_examples:
            f.write(json.dumps(example) + "\n")

    csv_path = OUTPUT_DIR / f"{args.out_prefix}.csv"
    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["transcript", "intent"])
        writer.writeheader()
        writer.writerows(all_examples)

    # Print class distribution summary
    actual_counts: dict[str, int] = {}
    for example in all_examples:
        actual_counts[example["intent"]] = actual_counts.get(example["intent"], 0) + 1

    print(f"\nWrote {len(all_examples)} examples to:")
    print(f"  {jsonl_path}")
    print(f"  {csv_path}")

    # Stratified train/eval split
    if args.split > 0 and args.split < 1:
        split_rng = random.Random(args.seed + 1000)
        by_cls: dict[str, list[dict]] = {}
        for e in all_examples:
            by_cls.setdefault(e["intent"], []).append(e)

        train_examples: list[dict] = []
        eval_examples: list[dict] = []
        for cls, cls_examples in by_cls.items():
            split_rng.shuffle(cls_examples)
            n_eval = max(1, int(len(cls_examples) * args.split))
            eval_examples.extend(cls_examples[:n_eval])
            train_examples.extend(cls_examples[n_eval:])

        split_rng.shuffle(train_examples)
        split_rng.shuffle(eval_examples)

        train_jsonl = OUTPUT_DIR / f"{args.out_prefix}-train.jsonl"
        train_csv = OUTPUT_DIR / f"{args.out_prefix}-train.csv"
        eval_jsonl = OUTPUT_DIR / f"{args.out_prefix}-eval.jsonl"
        eval_csv = OUTPUT_DIR / f"{args.out_prefix}-eval.csv"

        with train_jsonl.open("w") as f:
            for e in train_examples:
                f.write(json.dumps(e) + "\n")
        with train_csv.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["transcript", "intent"])
            writer.writeheader()
            writer.writerows(train_examples)
        with eval_jsonl.open("w") as f:
            for e in eval_examples:
                f.write(json.dumps(e) + "\n")
        with eval_csv.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["transcript", "intent"])
            writer.writeheader()
            writer.writerows(eval_examples)

        print(f"\nStratified split ({1-args.split:.0%} train / {args.split:.0%} eval):")
        print(f"  train: {len(train_examples)} examples")
        print(f"    {train_jsonl}")
        print(f"    {train_csv}")
        print(f"  eval:  {len(eval_examples)} examples")
        print(f"    {eval_jsonl}")
        print(f"    {eval_csv}")
    print(f"\nClass distribution:")
    for intent_class, count in sorted(actual_counts.items()):
        pct = count / len(all_examples) * 100
        print(f"  {intent_class:24s}  {count:6d}  ({pct:5.1f}%)")

    # Print sample examples per class
    print(f"\n{'='*60}")
    print("SAMPLE EXAMPLES PER CLASS (5 each):")
    print(f"{'='*60}")
    by_class: dict[str, list[dict]] = {}
    for e in all_examples:
        by_class.setdefault(e["intent"], []).append(e)

    for cls in ["chitchat", "pureKnowledge", "screenDescription",
                "screenAction", "research", "phoneLargeModel", "unknown"]:
        samples = by_class.get(cls, [])[:5]
        print(f"\n--- {cls} ---")
        for s in samples:
            print(f"  {s['transcript']}")

    # Print multi-action examples specifically
    print(f"\n{'='*60}")
    print("MULTI-ACTION EXAMPLES (sequential / parallel / parameterized):")
    print(f"{'='*60}")
    multi_examples = [
        e for e in all_examples
        if e["intent"] == "screenAction"
        and any(
            connector in e["transcript"]
            for connector in [" then ", " and then ", " after that ",
                              " at the same time ", " side by side",
                              " simultaneously", " and also "]
        )
    ]
    for s in multi_examples[:15]:
        print(f"  {s['transcript']}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
