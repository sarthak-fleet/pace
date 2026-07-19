#!/usr/bin/env python3
"""Generate supplementary training data for weak intent classes.

Targets the classes where the v1 model underperformed:
- research (77.9% — needs more diverse research patterns and clearer boundaries vs pureKnowledge)
- screenDescription (89.1% — needs more varied description queries)
- unknown (36.4% — needs more realistic unknown examples that don't leak into action/knowledge)
- phoneLargeModel (83.1% — needs more varied escalation phrasings)

Output: evals/intent-corpus/supplement.jsonl
"""
import json, random, os
from pathlib import Path

OUTPUT_DIR = Path(__file__).parent.parent / "evals" / "intent-corpus"

# ===========================================================================
# RESEARCH — massively expanded. Key: research implies MULTI-STEP investigation,
# synthesis across sources, or comparison. Must NOT overlap with pureKnowledge
# (single factual question). The differentiator: research = "go gather and
# synthesize", pureKnowledge = "tell me a fact you already know".
# ===========================================================================

RESEARCH_TOPICS_EXTRA = [
    # Tech trends
    "the latest javascript frameworks", "the rust adoption trend",
    "the webgpu landscape", "the state of edge computing",
    "the serverless evolution", "the microservices backlash",
    "the ai chip wars", "the gpu shortage recovery",
    "the data engineering ecosystem", "the observability tools market",
    "the ci/cd pipeline landscape", "the api gateway wars",
    "the database market shift", "the vector database space",
    "the embedding model benchmark", "the rag architecture patterns",
    "the agent framework comparison", "the tool calling standardization",
    "the structured output landscape", "the inference optimization space",
    "the model quantization techniques", "the speculative decoding research",
    "the kv cache optimization", "the attention mechanism variants",
    "the mixture of experts architecture", "the long context handling",
    # Science
    "the latest cancer treatment research", "the alzheimer's drug trials",
    "the longevity research field", "the brain computer interface progress",
    "the nuclear fusion timeline", "the battery technology breakthroughs",
    "the carbon capture technology", "the desalination advances",
    "the lab grown meat industry", "the vertical farming trend",
    "the gene therapy landscape", "the mrna vaccine platform",
    "the microbiome research", "the gut brain axis studies",
    "the psychedelic therapy research", "the ketamine treatment studies",
    # Economics / business
    "the remote work productivity studies", "the four day workweek trials",
    "the gig economy regulation", "the creator economy monetization",
    "the saas pricing models", "the subscription fatigue trend",
    "the d2c brand landscape", "the ecommerce logistics wars",
    "the fast fashion backlash", "the sustainable investing trend",
    "the esg reporting standards", "the carbon credit markets",
    "the private credit boom", "the venture debt landscape",
    "the startup valuation reset", "the ai startup bubble debate",
    # Culture / society
    "the social media regulation debate", "the ai copyright lawsuits",
    "the data privacy legislation", "the content moderation challenges",
    "the mis/disinformation landscape", "the deepfake detection technology",
    "the digital wellbeing movement", "the screen time research",
    "the online dating market", "the streaming fatigue phenomenon",
    "the podcast industry growth", "the newsletter economy",
    "the independent journalism landscape", "the local news crisis",
    # Health / lifestyle
    "the intermittent fasting research", "the keto diet studies",
    "the zone 2 cardio research", "the strength training longevity data",
    "the sleep optimization research", "the cold exposure studies",
    "the sauna health benefits", "the meditation research",
    "the gut health science", "the metabolic health movement",
    "the continuous glucose monitor trend", "the wearable health data",
    "the personalized nutrition space", "the mental health app market",
]

RESEARCH_PATTERNS_EXTRA = [
    # Explicit research verbs
    "research {}", "do research on {}", "do some research on {}",
    "research the {}", "deep research {}", "look into {}",
    "dig into {}", "investigate {}", "explore {}",
    "study up on {}", "read up on {}", "get me up to speed on {}",
    "get me smart on {}", "bone up on {}", "brush up on {}",
    # Source-finding
    "find sources on {}", "find me sources on {}",
    "find me the best sources on {}",
    "gather sources on {}", "collect sources on {}",
    "pull together sources on {}",
    "find recent papers on {}", "find the latest research on {}",
    "find academic papers on {}",
    "find me a literature review on {}",
    # Synthesis
    "summarize sources on {}", "summarise sources on {}",
    "synthesize the research on {}", "synthesise the research on {}",
    "give me a synthesis of {}", "give me a meta analysis of {}",
    "give me a meta-analysis of {}",
    "summarize the literature on {}", "summarise the literature on {}",
    "give me a literature review on {}",
    # Writeup / report
    "give me a writeup on {}", "give me a write-up on {}",
    "give me a report on {}", "write me a report on {}",
    "prepare a briefing on {}", "give me a briefing on {}",
    "give me a deep dive on {}", "do a deep dive on {}",
    "give me a thorough analysis of {}", "give me an in depth analysis of {}",
    "give me an in-depth analysis of {}",
    "i need a thorough analysis of {}",
    "i need a comprehensive overview of {}",
    "give me a comprehensive overview of {}",
    # Latest / state of
    "what's the latest on {}", "whats the latest on {}",
    "what's new with {}", "what's happening with {}",
    "what's going on with {}", "what's the current state of {}",
    "give me an overview of the {} landscape",
    "what are the trends in {}", "what's the outlook for {}",
    "where is {} heading", "what's the future of {}",
    "give me the lay of the land on {}",
    "catch me up on {}", "get me caught up on {}",
    # Multi-step research (clearly NOT pureKnowledge)
    "go research {} and give me a summary with citations",
    "research {} and find me the top 5 sources",
    "look into {} and write me a 2 page summary",
    "investigate {} and give me the key findings",
    "dig into {} and tell me what the experts are saying",
    "do a deep dive on {} and give me the pros and cons",
    "research {} and compare the top approaches",
    "look into {} and find me the latest data",
    "investigate {} and give me a timeline of key developments",
    "research {} and summarize the main arguments on both sides",
]

COMPARE_TOPICS_EXTRA = [
    # Tech
    "react vs vue vs svelte", "python vs rust vs go",
    "postgres vs mysql vs sqlite", "docker vs podman vs nerdctl",
    "kubernetes vs nomad vs docker swarm",
    "graphql vs rest vs grpc", "redis vs memcached vs dragonfly",
    "elasticsearch vs meilisearch vs typesense",
    "snowflake vs bigquery vs databricks",
    "datadog vs grafana vs prometheus",
    "terraform vs pulumi vs cdktf",
    "github actions vs gitlab ci vs circleci",
    "vercel vs netlify vs cloudflare pages",
    "tailwind vs styled components vs css modules",
    "vitest vs jest vs mocha", "playwright vs cypress vs selenium",
    "storybook vs ladle", "webpack vs vite vs turbopack",
    "next.js vs remix vs astro", "sveltekit vs next.js",
    "prisma vs drizzle vs sqlalchemy",
    # AI/ML
    "openai vs anthropic vs google", "gpt vs claude vs gemini",
    "llama vs qwen vs mistral", "pytorch vs jax vs tensorflow",
    "huggingface vs replicate vs together", "langchain vs llamaindex vs haystack",
    "pinecone vs weaviate vs qdrant", "mlx vs coreml vs metal",
    "lora vs qlora vs full finetuning", "sft vs dpo vs rlhf",
    "rag vs finetuning vs prompting", "distillation vs rlvr",
    # Productivity
    "notion vs obsidian vs roam", "linear vs jira vs asana",
    "slack vs teams vs discord", "figma vs sketch vs penpot",
    "vs code vs intellij vs neovim", "iterm2 vs warp vs ghostty",
    "raycast vs alfred vs spotlight", "homebrew vs nix vs macports",
    # Hardware
    "macbook pro vs thinkpad vs dell xps",
    "apple silicon vs intel vs amd", "m3 vs m4 vs m5",
    "rtx 4090 vs rtx 5090 vs a100",
    "mechanical switches cherry vs gateron vs zeal",
    # Lifestyle
    "apple music vs spotify vs tidal", "kindle vs kobo vs ipad",
    "standing desk vs sitting desk vs walking pad",
    "intermittent fasting vs keto vs mediterranean",
    "weights vs cardio vs hiit",
    "sauna vs steam room vs cold plunge",
    # Business
    "saas vs on premise vs hybrid", "aws vs gcp vs azure",
    "stripe vs paypal vs adyen", "notion vs confluence vs coda",
    "startup vs big tech vs consulting",
]

COMPARE_PATTERNS_EXTRA = [
    "compare {}", "compare {} for me", "compare {} and give me a recommendation",
    "{} which is better", "which is better {}", "{} pros and cons",
    "break down {}", "analyze {}", "evaluate {}",
    "{} which should i choose", "help me decide between {}",
    "give me a side by side of {}", "side by side comparison of {}",
    "{} head to head", "{} comparison",
    "what are the tradeoffs of {}", "weigh the pros and cons of {}",
    "compare and contrast {}", "give me a detailed comparison of {}",
    "which one wins on {}", "{} battle", "{} showdown",
]

# ===========================================================================
# SCREEN DESCRIPTION — expanded. Key: user wants to KNOW what's on screen,
# not DO something. Must not overlap with screenAction.
# ===========================================================================

SCREEN_DESC_PATTERNS_EXTRA = [
    # Direct description requests
    "what's on the screen", "what's on my screen", "what's on screen",
    "what am i looking at", "what's this", "what is this",
    "describe what i'm looking at", "describe what's on screen",
    "describe the screen", "describe my screen",
    "describe what's in front of me", "describe this window",
    "describe what you see", "describe the current view",
    "describe the page", "describe the app",
    "describe the interface", "describe the layout",
    "describe what's open", "describe what's visible",
    "describe everything on screen", "describe the content",
    # Summary requests
    "summarize what's on screen", "summarise what's on screen",
    "summarize this page", "summarise this page",
    "summarize what i'm looking at", "summarise what i'm looking at",
    "give me the gist of this", "give me the gist of what's on screen",
    "give me a summary of this screen", "give me a quick summary of this",
    "give me the highlights of this page",
    "what's the gist of this", "what's the summary here",
    "give me the tldr of this", "tl;dr this for me",
    "what's the main idea here", "what's this about",
    "what's this page about", "what's this window about",
    "what's this app about", "what's this screen about",
    "what's this document about", "what's this article about",
    "what's this email about", "what's this message about",
    "what's this website about", "what's this tab about",
    # Reading requests (screen content)
    "read this", "read the screen", "read what's on screen",
    "read this to me", "read this out loud", "read this aloud",
    "read me what's on the screen", "read me this page",
    "read me this document", "read me this email",
    "read me this article", "read me what it says",
    "read the text on screen", "read the content",
    "read out what's there", "read it out",
    "what does this say", "what does the screen say",
    "what does this show", "what does this page say",
    "what does this document say", "what does this email say",
    "what does this article say", "what does the text say",
    # Identification
    "what app is this", "what app am i in", "what application is this",
    "what window is this", "what's this window called",
    "what page am i on", "what site am i on",
    "what website is this", "what tab am i on",
    "what document am i in", "what file is this",
    "what view is this", "what screen is this",
    "what program is this", "what tool am i using",
    # Scanning / listing
    "scan the screen", "scan this page", "scan what's here",
    "what can you see", "what do you see",
    "what can you see on screen", "what do you see on the screen",
    "what's visible", "what's visible on screen",
    "what's on display", "what's showing",
    "what's in front of me", "what's open",
    "tell me what's on the screen", "tell me what's open",
    "tell me what's visible", "tell me what you can see",
    "tell me what's here", "tell me what's on this page",
    "tell me what's on this screen", "tell me what's in this window",
    "walk me through what's on screen", "walk me through this page",
    "walk me through what's here", "walk me through the interface",
    "lay out what's on the screen", "lay out what's here",
    "list what's on screen", "list what's open",
    "what are my options here", "what choices do i have here",
    "what buttons are on screen", "what can i click here",
    "what menus are available", "what's in the toolbar",
    # Context awareness
    "am i in the right app", "is this the right window",
    "where am i", "where am i on the screen",
    "what section am i in", "what part of the app am i in",
    "what view am i looking at", "what tab is open",
    "is this the right page", "am i on the right screen",
    "what's the current state of the screen",
    "what's happening on screen", "what's happening here",
    "what's going on on the screen", "what's going on here",
    # Specific content questions (still description, not action)
    "what's the title of this page", "what's the heading here",
    "what's the main content here", "what's the sidebar showing",
    "what's in the search bar", "what's in the address bar",
    "what's the url here", "what's the current url",
    "what's selected", "what's highlighted",
    "what's in focus", "what field am i in",
    "what's the cursor on", "what's the mouse over",
    "what's at the top of the screen", "what's at the bottom",
    "what's in the status bar", "what's in the menu bar",
    "what notifications are showing", "what alerts are up",
    "what dialog is open", "what popup is showing",
    "what error is showing", "what message is displayed",
]

# ===========================================================================
# UNKNOWN — expanded with more realistic out-of-scope examples.
# Key: these should NOT contain action verbs or knowledge patterns.
# The goal is examples that are genuinely ambiguous or out of Pace's scope.
# ===========================================================================

UNKNOWN_EXTRA = [
    # Emotional reactions (not commands)
    "wow that's cool", "oh that's interesting", "huh weird",
    "that's strange", "that's unexpected", "well that's odd",
    "huh i didn't expect that", "oh nice", "ah i see",
    "hmm that's curious", "interesting", "fascinating",
    "that's ridiculous", "that's absurd", "that's hilarious",
    "that's funny", "lol", "lmao", "omg",
    "what a mess", "what a disaster", "what a mess this is",
    "this is a nightmare", "this is a disaster",
    "what a joke", "what a waste of time",
    # Thinking out loud (not commands)
    "let me think about this", "give me a second to think",
    "hold on let me think", "wait let me think about this",
    "hmm let me consider", "i need to think about this",
    "let me ponder this for a moment", "i'm still deciding",
    "i'm not sure yet", "i haven't decided",
    "let me sleep on it", "i'll get back to you",
    "maybe later", "not right now", "perhaps another time",
    "i'll think about it", "let me check my schedule first",
    # Conversational continuations (ambiguous without context)
    "and then what", "so what happened next", "go on",
    "continue with that", "what else", "anything else",
    "is there more", "what's next", "keep going",
    "tell me more about that", "elaborate on that",
    "what do you mean by that", "can you clarify",
    "i don't understand", "i'm confused", "i'm lost",
    "wait what", "huh what", "what was that again",
    "can you repeat that", "say that again",
    "i missed that", "i didn't catch that",
    # Off-scope device control (not Mac screen actions)
    "turn on the lights", "turn off the lights",
    "dim the lights", "set the thermostat to 72",
    "lock the front door", "unlock the back door",
    "open the garage door", "close the garage door",
    "start the dishwasher", "start the washing machine",
    "turn on the tv", "turn off the tv",
    "change the channel", "turn up the tv volume",
    "start the robot vacuum", "stop the robot vacuum",
    "start the coffee maker", "preheat the oven to 350",
    "set the alarm for 7 am", "arm the security system",
    "water the garden", "start the sprinklers",
    # Physical world requests (not screen actions)
    "call 911", "call an ambulance", "call the police",
    "call the fire department", "call poison control",
    "order me an uber", "order me a lyft",
    "order me food", "order me a pizza",
    "order me coffee", "order me groceries",
    "book me a flight", "book me a hotel",
    "book me a restaurant", "book me an uber",
    "buy me a coffee", "buy me lunch",
    # Questions about the real world (not screen, not knowledge Pace can answer)
    "is it going to rain", "is it going to snow",
    "is it going to be hot today", "is it going to be cold",
    "what's the weather like outside",
    "what's the temperature outside",
    "what's the air quality today",
    "is there traffic on the way to work",
    "how long will it take to get to the airport",
    "what time does the store close",
    "what time does the pharmacy open",
    "is the restaurant still open",
    "are there any good restaurants nearby",
    # Meta questions about Pace (NOT "what can you do" which is pureKnowledge)
    "are you working", "is your mic on",
    "can you hear me properly", "is the audio working",
    "are you recording", "is this being logged",
    "are you sending my data anywhere", "is this private",
    "are you connected to the internet",
    "what version are you", "when were you last updated",
    "are you up to date", "do you need to be updated",
    "is your battery ok", "are you running low on memory",
    "is the fan supposed to be this loud",
    # Vague references (need screen context that isn't available)
    "click that", "open that", "close that",
    "go there", "navigate there", "select this one",
    "choose that option", "pick the first one",
    "do the thing", "do that thing", "do the stuff",
    "you know the one i mean", "the usual thing",
    "the same as last time", "like before",
    # Incomplete / trailing off
    "i was going to ask you", "i wanted to",
    "i was thinking maybe", "i wonder if",
    "actually never mind", "wait no",
    "actually forget it", "no wait",
    "hmm actually", "well actually never mind",
    # System-level complaints (not actionable)
    "my mac is slow", "my computer is lagging",
    "the fan is too loud", "my battery is draining fast",
    "my mac is getting hot", "the screen is too bright",
    "the screen is too dim", "the text is too small",
    "the colors look wrong", "the display is flickering",
    "my wifi is slow", "my bluetooth isn't working",
    "my headphones won't connect", "my mouse is lagging",
    "my keyboard is acting up", "the trackpad is jumpy",
]

# ===========================================================================
# PHONE LARGE MODEL — expanded escalation phrasings
# ===========================================================================

LARGE_MODEL_EXTRA = [
    # Direct escalation
    "phone a large model", "ask the big model", "use the big model",
    "use a large model", "call the large model", "hard mode",
    "think deeply", "use a stronger model", "phone a friend",
    "ask the big brain", "use the big brain", "escalate this",
    "this needs the big model", "use your strongest model for this",
    "use the most capable model", "bring out the big guns",
    "i need the smart model for this", "this is too hard for the local model",
    "route this to the large model", "use the cloud model for this one",
    "ask the frontier model", "use the frontier model",
    "this needs frontier level reasoning", "deep think this",
    "think really hard about this", "put on your thinking cap",
    "use maximum reasoning", "use extended thinking",
    "use the reasoning model", "this needs o1 level thinking",
    "this needs deep reasoning", "use the powerful model",
    "use the heavy model", "switch to the large model",
    "use the big one for this", "upgrade to the big model",
    "bump this up to the large model", "promote this to the big model",
    "hand this to the big model", "pass this to the frontier model",
    "let the big model handle this", "let the frontier model try this",
    "i want the best model for this", "give me your best model",
    "use the premium model", "use the pro model",
    "use the advanced model", "use the expert model",
    "this is beyond the small model", "the small model can't handle this",
    "this is too complex for local", "this needs a bigger brain",
    "this needs more horsepower", "this needs more compute",
    "this is a hard problem", "this is a complex problem",
    "this is a tricky one", "this is a tough one",
    "this is a challenging question", "this is a difficult question",
    "this requires deep thought", "this requires careful reasoning",
    "this requires multi step reasoning", "this requires chain of thought",
    "i need a high quality answer", "i need a thorough answer",
    "i need a detailed answer", "i need a well reasoned answer",
    "i need an expert answer", "i need a nuanced answer",
    "don't give me a quick answer", "don't just guess",
    "really think about this one", "take your time on this",
    "this is important get it right", "this is critical",
    "this is high stakes", "this is a big decision",
    "switch to gpt", "switch to claude", "switch to opus",
    "use gpt for this", "use claude for this", "use opus for this",
    "ask gpt", "ask claude", "ask opus",
    "use chatgpt for this", "use gemini for this",
    "route to chatgpt", "route to claude", "route to gemini",
    "i want the cloud model for this", "use the cloud for this",
    "this one goes to the cloud", "cloud mode for this one",
    "activate deep thinking", "activate extended reasoning",
    "activate hard mode", "enable deep reasoning",
    "turn on deep thinking", "turn on hard mode",
    "maximum effort on this one", "give this your all",
    "this is a phd level question", "this is an expert level question",
    "this is a research level question", "this is a graduate level question",
]


def apply_light_variation(text: str, rng: random.Random) -> str:
    """Light variation — just fillers and wake phrases, no heavy mutation."""
    variations = [
        "",  # no variation (most common)
        "", "",
        "hey pace, ",  # wake phrase
        "pace, ",
        "ok pace, ",
        "uh ",  # filler
        "um ",
        "hmm ",
        "so ",
        "like ",
        "okay ",
    ]
    prefix = rng.choice(variations)
    suffix = rng.choice(["", "", "", " please", " thanks", " if you can"])
    return f"{prefix}{text}{suffix}".strip()


def generate_supplement():
    rng = random.Random(123)
    examples = []
    seen = set()

    # Research: ~8000 examples
    research_count = 0
    while research_count < 8000:
        if rng.random() < 0.55:
            topic = rng.choice(RESEARCH_TOPICS_EXTRA)
            pattern = rng.choice(RESEARCH_PATTERNS_EXTRA)
            if pattern.count("{}") == 1:
                base = pattern.format(topic)
            else:
                continue
        elif rng.random() < 0.5:
            compare = rng.choice(COMPARE_TOPICS_EXTRA)
            pattern = rng.choice(COMPARE_PATTERNS_EXTRA)
            base = pattern.format(compare)
        else:
            # Multi-step research (strong signal)
            topic = rng.choice(RESEARCH_TOPICS_EXTRA)
            pattern = rng.choice([p for p in RESEARCH_PATTERNS_EXTRA if " and " in p or " and give" in p])
            base = pattern.format(topic)
        text = apply_light_variation(base, rng)
        if text not in seen:
            seen.add(text)
            examples.append({"transcript": text, "intent": "research"})
            research_count += 1

    # Screen description: ~6000 examples
    desc_count = 0
    while desc_count < 6000:
        pattern = rng.choice(SCREEN_DESC_PATTERNS_EXTRA)
        text = apply_light_variation(pattern, rng)
        if text not in seen:
            seen.add(text)
            examples.append({"transcript": text, "intent": "screenDescription"})
            desc_count += 1

    # Unknown: ~5000 examples
    unknown_count = 0
    while unknown_count < 5000:
        base = rng.choice(UNKNOWN_EXTRA)
        text = apply_light_variation(base, rng)
        if text not in seen:
            seen.add(text)
            examples.append({"transcript": text, "intent": "unknown"})
            unknown_count += 1

    # Phone large model: ~3000 examples
    plm_count = 0
    while plm_count < 3000:
        base = rng.choice(LARGE_MODEL_EXTRA)
        text = apply_light_variation(base, rng)
        if text not in seen:
            seen.add(text)
            examples.append({"transcript": text, "intent": "phoneLargeModel"})
            plm_count += 1

    rng.shuffle(examples)
    return examples


def main():
    examples = generate_supplement()
    print(f"Generated {len(examples)} supplementary examples")

    from collections import Counter
    counts = Counter(e["intent"] for e in examples)
    for cls, cnt in sorted(counts.items()):
        print(f"  {cls:24s}  {cnt:6d}")

    out_jsonl = OUTPUT_DIR / "supplement.jsonl"
    out_csv = OUTPUT_DIR / "supplement.csv"
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    with out_jsonl.open("w") as f:
        for e in examples:
            f.write(json.dumps(e) + "\n")

    import csv
    with out_csv.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["transcript", "intent"])
        writer.writeheader()
        writer.writerows(examples)

    print(f"\nWrote to:")
    print(f"  {out_jsonl}")
    print(f"  {out_csv}")

    # Print samples
    print("\nSamples per class:")
    by_cls = {}
    for e in examples:
        by_cls.setdefault(e["intent"], []).append(e)
    for cls in ["research", "screenDescription", "unknown", "phoneLargeModel"]:
        print(f"\n--- {cls} ---")
        for s in by_cls.get(cls, [])[:5]:
            print(f"  {s['transcript']}")


if __name__ == "__main__":
    main()
