#!/usr/bin/env python3
"""Generate v2 supplement — targeted at the remaining weak spots.

Key problems from v2 eval:
1. unknown (40.9%): 151/599 unknown examples misclassified as screenAction
   because they contain action verbs for NON-Mac actions (home automation,
   booking, other assistants). Need to teach the model that action verbs
   for non-Mac devices = unknown.
2. research (85.0%): 101/900 leak to pureKnowledge because "what's going on"
   patterns overlap with "what's" knowledge patterns. Need more research
   examples with these patterns.
3. screenDescription (93.1%): 104 leak to pureKnowledge. Need clearer
   screen-context signals.
"""
import json, random
from pathlib import Path
from collections import Counter

OUTPUT_DIR = Path(__file__).parent.parent / "evals" / "intent-corpus"

# ===========================================================================
# UNKNOWN — action verbs for NON-Mac targets. This is the critical fix.
# The model needs to learn: "turn on the lights" = unknown, "turn on the
# volume" = screenAction. The differentiator is the TARGET, not the verb.
# ===========================================================================

UNKNOWN_NON_MAC_ACTIONS = [
    # Home automation (NOT Mac screen actions)
    "turn on the lights", "turn off the lights", "dim the lights",
    "brighten the lights", "set the lights to warm white",
    "set the bedroom lights to blue", "set the kitchen lights to 50 percent",
    "change the light color to red", "change the lights to blue",
    "turn on the bedroom lights", "turn off the bedroom lights",
    "turn on the kitchen lights", "turn off the kitchen lights",
    "turn on the living room lights", "turn off the living room lights",
    "turn on the bathroom lights", "turn off the bathroom lights",
    "turn on the hallway lights", "turn off the hallway lights",
    "turn on the porch light", "turn off the porch light",
    "turn on the garage lights", "turn off the garage lights",
    "set the thermostat to 72", "set the thermostat to 68",
    "set the temperature to 70 degrees", "set the temperature to 65",
    "turn up the heat", "turn down the heat",
    "turn up the thermostat", "turn down the thermostat",
    "raise the temperature", "lower the temperature",
    "set the ac to 72", "turn on the air conditioner",
    "turn off the air conditioner", "turn on the heater",
    "turn off the heater", "set the climate control to 70",
    # Doors / locks
    "lock the front door", "unlock the front door",
    "lock the back door", "unlock the back door",
    "lock all doors", "unlock all doors",
    "lock the garage", "unlock the garage",
    "open the garage door", "close the garage door",
    "open the front gate", "close the front gate",
    "open the blinds", "close the blinds",
    "open the curtains", "close the curtains",
    "open the window", "close the window",
    # Appliances
    "start the dishwasher", "stop the dishwasher",
    "start the washing machine", "stop the washing machine",
    "start the dryer", "stop the dryer",
    "start the robot vacuum", "stop the robot vacuum",
    "send the robot vacuum home", "start the roomba",
    "stop the roomba", "start the coffee maker",
    "start brewing coffee", "preheat the oven to 350",
    "preheat the oven to 425", "set the oven to 375",
    "turn on the microwave", "turn off the microwave",
    "start the slow cooker", "turn on the air fryer",
    # TV / entertainment (NOT Mac)
    "turn on the tv", "turn off the tv",
    "change the channel to espn", "change the channel to cnn",
    "change the channel to abc", "change the channel to nbc",
    "change the channel to 5", "turn up the tv volume",
    "turn down the tv volume", "mute the tv", "unmute the tv",
    "set the apple tv to netflix", "set the apple tv to hulu",
    "set the apple tv to disney", "set the apple tv to youtube",
    "set the roku to netflix", "set the roku to hulu",
    "play netflix on the tv", "play hulu on the tv",
    "play youtube on the tv", "play disney on the tv",
    "pause the tv", "resume the tv", "rewind the tv",
    "fast forward the tv", "skip the intro on the tv",
    # Security
    "arm the security system", "disarm the security system",
    "arm the alarm", "disarm the alarm",
    "set the alarm to away mode", "set the alarm to home mode",
    "turn on the security cameras", "turn off the security cameras",
    "show me the front door camera", "show me the backyard camera",
    "show me the garage camera", "show me the living room camera",
    # Sprinklers / garden
    "start the sprinklers", "stop the sprinklers",
    "water the garden", "water the lawn",
    "water the plants", "start the drip system",
    # Other assistants (NOT Pace)
    "hey siri play my morning playlist", "hey siri set a timer",
    "hey siri set an alarm for 7 am", "hey siri send a message to mom",
    "hey siri what's the weather", "hey siri call dad",
    "hey siri remind me to call mom", "hey siri add milk to my grocery list",
    "hey siri navigate home", "hey siri play jazz",
    "alexa turn off the lights", "alexa play music",
    "alexa set a timer", "alexa add milk to my shopping list",
    "alexa what's the weather", "alexa play spotify",
    "alexa turn up the volume", "alexa turn down the volume",
    "alexa read me a book", "alexa tell me a joke",
    "alexa set a reminder", "alexa call john",
    "ok google navigate home", "ok google what's the weather",
    "ok google set a timer", "ok google play music",
    "ok google turn off the lights", "ok google send a text",
    "ok google add an event", "ok google remind me to call mom",
    "ok google play jazz", "ok google set the thermostat to 72",
    # Real-world services (NOT Mac screen actions)
    "order pizza from dominos", "order pizza from pizza hut",
    "order food from doordash", "order food from uber eats",
    "order me a coffee", "order me coffee from starbucks",
    "order me groceries", "order groceries from instacart",
    "order me an uber", "order me a lyft",
    "call me an uber", "call me a lyft",
    "call a cab", "call a taxi", "call a ride",
    "book me a flight", "book a flight to london",
    "book a flight to new york", "book a flight to tokyo",
    "book me a hotel", "book a hotel in paris",
    "book a hotel in new york", "book a hotel room",
    "book me a restaurant", "book a table for two",
    "book a reservation", "book a doctor's appointment",
    "book a dentist appointment", "book a haircut",
    "book a car wash", "book a massage",
    "schedule a car wash", "schedule a pickup",
    "post on facebook", "post on instagram", "post on twitter",
    "post on x", "post on linkedin", "post on tiktok",
    "post a story on instagram", "post a reel",
    "send money via paypal", "send money via venmo",
    "send money via cash app", "send money via zelle",
    "pay my electric bill", "pay my water bill",
    "pay my internet bill", "pay my rent",
    "pay my credit card", "pay my mortgage",
    # Emergency (NOT Mac)
    "call 911", "call an ambulance", "call the police",
    "call the fire department", "call poison control",
    "call emergency services", "call my emergency contact",
    # Physical world
    "is it going to rain", "is it going to snow",
    "is it going to be hot today", "is it going to be cold",
    "what's the weather like outside", "what's the weather tomorrow",
    "what's the weather this weekend", "will it rain today",
    "will it snow tomorrow", "how hot is it outside",
    "how cold is it outside", "what's the temperature outside",
    "what's the air quality today", "is there a storm coming",
    "is there traffic on the way to work", "how long will it take to get home",
    "how long will it take to get to the airport",
    "what time does the store close", "what time does the store open",
    "what time does the pharmacy open", "what time does the pharmacy close",
    "is the restaurant still open", "is the grocery store open",
    "are there any good restaurants nearby", "find me a gas station",
    "find me an atm", "find me a pharmacy",
]

# Unknown WITHOUT action verbs — emotional, incomplete, meta
UNKNOWN_NO_ACTION = [
    # Emotional reactions
    "wow that's cool", "oh that's interesting", "huh weird",
    "that's strange", "that's unexpected", "well that's odd",
    "oh nice", "ah i see", "hmm that's curious",
    "interesting", "fascinating", "that's ridiculous",
    "that's absurd", "that's hilarious", "that's funny",
    "lol", "lmao", "omg", "what a mess", "what a disaster",
    "this is a nightmare", "what a joke", "what a waste of time",
    "i love this", "this is great", "this is amazing",
    "this is terrible", "this is awful", "this is bad",
    "this is good", "this is fine", "this is okay",
    "this is interesting", "this is boring", "this is exciting",
    "this is beautiful", "this is ugly", "this is weird",
    "this is cool", "this is dumb", "this is stupid",
    "this is smart", "this is clever", "this is brilliant",
    "this is genius", "this is insane", "this is crazy",
    "this is wild", "this is wild man", "this is nuts",
    "this is bananas", "this is ridiculous", "this is absurd",
    # Thinking / deciding
    "let me think about this", "give me a second to think",
    "hold on let me think", "wait let me think about this",
    "hmm let me consider", "i need to think about this",
    "let me ponder this", "i'm still deciding",
    "i'm not sure yet", "i haven't decided",
    "let me sleep on it", "i'll get back to you",
    "maybe later", "not right now", "perhaps another time",
    "i'll think about it", "let me check my schedule first",
    "should i go back to school", "what should i do with my life",
    "should i quit my job", "should i move to a new city",
    "should i buy or rent", "should i get a dog",
    "should i get a cat", "should i learn python",
    "should i learn rust", "should i learn go",
    # Incomplete / trailing off
    "i was going to ask you", "i wanted to",
    "i was thinking maybe", "i wonder if",
    "actually never mind", "wait no",
    "actually forget it", "no wait",
    "hmm actually", "well actually never mind",
    "you know what", "never mind", "forget it",
    "nothing", "nevermind", "no",
    "wait", "hmm", "uh", "um", "uhh", "umm",
    "let me see", "give me a moment",
    "hold on", "wait a second", "wait a minute",
    "one moment", "just a second",
    # Vague references
    "do the thing", "do that thing", "do the stuff",
    "you know the one i mean", "the usual thing",
    "the same as last time", "like before",
    "click that", "open that", "close that",
    "go there", "navigate there", "select this one",
    "choose that option", "pick the first one",
    "the project", "the window", "the text",
    "the email", "the reminder", "the phone number",
    "here", "there", "this", "that",
    "fine", "okay", "alright", "sure", "yes",
    # Meta questions about Pace
    "are you working", "is your mic on",
    "can you hear me properly", "is the audio working",
    "are you recording", "is this being logged",
    "are you sending my data anywhere", "is this private",
    "are you connected to the internet",
    "what version are you", "when were you last updated",
    "are you up to date", "do you need to be updated",
    "is your battery ok", "are you running low on memory",
    "is the fan supposed to be this loud",
    "do you ever just stare at the ceiling",
    "redo", "undo", "do it again", "try again",
    # System complaints
    "my mac is slow", "my computer is lagging",
    "the fan is too loud", "my battery is draining fast",
    "my mac is getting hot", "the screen is too bright",
    "the screen is too dim", "the text is too small",
    "the colors look wrong", "the display is flickering",
    "my wifi is slow", "my bluetooth isn't working",
    "my headphones won't connect", "my mouse is lagging",
    "my keyboard is acting up", "the trackpad is jumpy",
    # Questions about the real world (not screen, not knowledge Pace can answer)
    "how tall is the eiffel tower", "how tall is mount everest",
    "what's the capital of france", "what's the capital of japan",
    "what does gracias mean", "what does arigato mean",
    "how do i deal with stress", "how do i deal with anxiety",
    "convert 100 fahrenheit to celsius", "convert 100 celsius to fahrenheit",
    "convert 10 miles to kilometers", "convert 10 kilometers to miles",
    "convert 1 cup to milliliters", "convert 1 pound to kilograms",
    "is this a good deal", "should i buy this",
    "would it be possible to", "can you help me decide",
    "write me a story", "write me a poem", "write me a song",
    "tell me a joke", "tell me a riddle", "tell me a fun fact",
    "how about", "what about", "why does",
    "this reminds me of something",
]

# ===========================================================================
# RESEARCH — with knowledge-pattern overlaps. These must be clearly
# multi-step research, not single factual questions.
# ===========================================================================

RESEARCH_WITH_KNOWLEDGE_PATTERNS = [
    # "what's" patterns that are research (multi-step)
    "what's going on with {}", "what's happening with {}",
    "what's new with {}", "what's the latest on {}",
    "what's the current state of {}", "what's the outlook for {}",
    "what's the future of {}", "what's trending in {}",
    "what's the consensus on {}", "what's the debate around {}",
    "what's the story with {}", "what's the deal with {}",
    "what's the word on {}", "what's the buzz about {}",
    "what's being said about {}", "what's the narrative around {}",
    "what's the sentiment on {}", "what's the data saying about {}",
    "what's the research saying about {}", "what's the evidence on {}",
    # "how" patterns that are research
    "how is {} evolving", "how is {} changing",
    "how is {} progressing", "how is {} developing",
    "how does {} compare to alternatives", "how does {} stack up",
    # "tell me about" that's research (multi-step)
    "tell me about the latest developments in {}",
    "tell me about the current state of {}",
    "tell me about the trends in {}",
    "tell me about the research on {}",
    "tell me about the debate around {}",
    "tell me about the controversy around {}",
    "tell me about the arguments for and against {}",
    # "explain" that's research
    "explain the landscape of {}", "explain the state of {}",
    "explain the trends in {}", "explain the debate around {}",
    # "describe" that's research
    "describe the current state of {}", "describe the landscape of {}",
    "describe the trends in {}", "describe the evolution of {}",
]

RESEARCH_TOPICS_FOR_KNOWLEDGE = [
    "the ai industry", "the chip shortage", "the housing market",
    "the job market", "the stock market", "the crypto market",
    "the ev market", "the battery industry", "the solar industry",
    "the wind energy sector", "the nuclear energy debate",
    "the fusion energy research", "the quantum computing field",
    "the biotech industry", "the pharma industry",
    "the telemedicine trend", "the mental health crisis",
    "the obesity epidemic", "the aging population",
    "the birth rate decline", "the immigration debate",
    "the climate policy landscape", "the carbon tax debate",
    "the ai regulation debate", "the data privacy movement",
    "the open source movement", "the creator economy",
    "the gig economy", "the remote work transition",
    "the four day workweek", "the union movement",
    "the minimum wage debate", "the universal basic income debate",
    "the student debt crisis", "the housing affordability crisis",
    "the inflation situation", "the interest rate environment",
    "the recession risk", "the supply chain recovery",
    "the semiconductor race", "the ai chip wars",
    "the space race", "the mars colonization plans",
    "the satellite internet race", "the quantum supremacy race",
    "the gene editing revolution", "the crispr patent battle",
    "the mrna vaccine platform", "the cancer immunotherapy progress",
    "the alzheimer's research", "the longevity research",
    "the brain computer interface field", "the neuralink progress",
    "the metaverse", "the ar vr landscape",
    "the wearable computing trend", "the smart home market",
    "the electric airplane industry", "the flying car development",
    "the autonomous vehicle industry", "the self driving car regulation",
    "the drone delivery industry", "the supersonic jet comeback",
    "the high speed rail debate", "the public transit crisis",
    "the microplastics problem", "the ocean pollution crisis",
    "the deforestation crisis", "the biodiversity loss",
    "the overfishing problem", "the water scarcity crisis",
    "the desertification problem", "the permafrost melting",
    "the glacier retreat", "the sea level rise",
    "the coral reef bleaching", "the amazon rainforest loss",
]

# ===========================================================================
# SCREEN DESCRIPTION — with clearer screen-context signals
# ===========================================================================

SCREEN_DESC_CLEAR = [
    # Explicit "screen" references
    "what's on the screen right now", "what's on my screen",
    "what's on the screen", "what's on screen",
    "read what's on the screen", "read the screen for me",
    "scan the screen for me", "scan my screen",
    "describe the screen for me", "describe my screen",
    "describe what's on the screen", "describe what's on my screen",
    "describe everything on the screen", "describe everything on my screen",
    "summarize what's on the screen", "summarise what's on the screen",
    "summarize my screen", "summarise my screen",
    "what's visible on the screen", "what's visible on my screen",
    "what's showing on the screen", "what's showing on my screen",
    "what can you see on the screen", "what do you see on the screen",
    "tell me what's on the screen", "tell me what's on my screen",
    "read me what's on the screen", "read me what's on my screen",
    "walk me through what's on the screen",
    "lay out what's on the screen",
    "list what's on the screen", "list what's on my screen",
    "what's happening on the screen", "what's happening on my screen",
    # "looking at" patterns
    "what am i looking at", "what am i looking at right now",
    "describe what i'm looking at", "describe what i am looking at",
    "summarize what i'm looking at", "summarise what i'm looking at",
    "give me the gist of what i'm looking at",
    "what's the gist of what i'm looking at",
    "tell me what i'm looking at", "tell me what i am looking at",
    "read what i'm looking at", "read what i am looking at",
    "explain what i'm looking at", "explain what i am looking at",
    "walk me through what i'm looking at",
    # "this" patterns (screen context implied)
    "what's this", "what is this", "what's this about",
    "what's this page about", "what's this window about",
    "what's this app about", "what's this screen about",
    "what's this document about", "what's this email about",
    "what's this article about", "what's this website about",
    "what's this tab about", "what's this file about",
    "what's this for", "what is this for",
    "what's this all about", "what is this all about",
    "give me the gist of this", "give me the gist of this page",
    "give me the gist of this screen", "give me the gist of this window",
    "give me the gist of this document", "give me the gist of this email",
    "give me the gist of this article", "give me the gist of this website",
    "summarize this", "summarise this",
    "summarize this page", "summarise this page",
    "summarize this screen", "summarise this screen",
    "summarize this window", "summarise this window",
    "summarize this document", "summarise this document",
    "summarize this email", "summarise this email",
    "summarize this article", "summarise this article",
    "read this", "read this to me", "read this out loud",
    "read this aloud", "read this page", "read this screen",
    "read this document", "read this email", "read this article",
    "read me this", "read me this page", "read me this screen",
    "read me this document", "read me this email", "read me this article",
    "what does this say", "what does this show",
    "what does this page say", "what does this screen say",
    "what does this document say", "what does this email say",
    "what does this article say", "what does the screen say",
    "what does the page say", "what does the text say",
    # App / window identification
    "what app is this", "what app am i in", "what application is this",
    "what window is this", "what's this window called",
    "what page am i on", "what site am i on",
    "what website is this", "what tab am i on",
    "what document am i in", "what file is this",
    "what view is this", "what screen is this",
    "what program is this", "what tool am i using",
    "where am i", "where am i on the screen",
    "what section am i in", "what part of the app am i in",
    "what view am i looking at", "what tab is open",
    "am i in the right app", "is this the right window",
    "is this the right page", "am i on the right screen",
    # Content questions (about screen content, not general knowledge)
    "what's the title of this page", "what's the heading here",
    "what's the main content here", "what's the sidebar showing",
    "what's in the search bar", "what's in the address bar",
    "what's the url here", "what's the current url",
    "what's selected", "what's highlighted",
    "what's in focus", "what field am i in",
    "what's at the top of the screen", "what's at the bottom",
    "what's in the status bar", "what's in the menu bar",
    "what notifications are showing", "what alerts are up",
    "what dialog is open", "what popup is showing",
    "what error is showing", "what message is displayed",
    "what are my options here", "what choices do i have here",
    "what buttons are on screen", "what can i click here",
    "what menus are available", "what's in the toolbar",
    # "can you see" patterns
    "what can you see", "what do you see",
    "can you see my screen", "can you see what's on my screen",
    "can you see what i'm looking at",
    "can you read what's on my screen",
    "can you read what's in front of me",
    "can you tell me what's on my screen",
    "can you describe what's on my screen",
    "can you describe what you see",
    "can you describe what i'm looking at",
    "can you summarize what's on screen",
    "can you summarise what's on screen",
]

# ===========================================================================
# PURE KNOWLEDGE — clearer single-fact questions to maintain boundary
# ===========================================================================

PURE_KNOWLEDGE_CLEAR = [
    "what is {}", "what's {}", "what does {} mean",
    "explain {}", "tell me about {}", "how does {} work",
    "what is the definition of {}", "what's the definition of {}",
    "what are {}", "what is a {}", "what's a {}",
    "who is {}", "who was {}", "who invented {}",
    "when was {} invented", "where is {}",
    "what is {} in plain english", "what's {} in simple terms",
    "remind me what {} is", "remind me what {} means",
    "what does {} stand for", "what does {} do",
    "why is {} important", "why do we use {}",
    "what's the difference between {} and {}",
    "what is the difference between {} and {}",
    "how do i {}", "how to {}", "how do you {}",
]

PURE_KNOWLEDGE_TOPICS = [
    "html", "css", "javascript", "python", "rust", "go",
    "docker", "kubernetes", "git", "github", "gitlab",
    "rest api", "graphql", "grpc", "websockets",
    "sql", "nosql", "postgres", "mysql", "redis",
    "machine learning", "deep learning", "neural networks",
    "transformers", "attention mechanism", "embeddings",
    "fine tuning", "rlhf", "lora", "quantization",
    "recursion", "dynamic programming", "big o notation",
    "design patterns", "solid principles", "clean code",
    "microservices", "monolith", "serverless", "event driven architecture",
    "ci/cd", "devops", "infrastructure as code",
    "tcp/ip", "http", "https", "dns", "cdn",
    "encryption", "hashing", "jwt", "oauth",
    "the internet", "the cloud", "edge computing",
    "photosynthesis", "mitosis", "meiosis", "dna",
    "gravity", "relativity", "quantum mechanics",
    "the stock market", "inflation", "gdp", "recession",
    "blockchain", "cryptocurrency", "nft",
    "agile", "scrum", "kanban", "waterfall",
    "type theory", "functional programming", "oop",
]


def apply_light_variation(text: str, rng: random.Random) -> str:
    variations = ["", "", "", "hey pace, ", "pace, ", "ok pace, ", "okay pace, ",
                  "uh ", "um ", "hmm ", "so ", "like ", "okay ", "yo pace, ",
                  "hello pace, ", "hi pace, ", "quick question, ", "hey, ",
                  "can you ", "could you ", "i need you to ", "i want you to ",
                  "let's ", "how about ", "please "]
    suffixes = ["", "", "", " please", " thanks", " if you can", " for me",
                " please", " thanks", " right now", " now", " today",
                " tomorrow", " later", " first", " again", " this time"]
    return f"{rng.choice(variations)}{text}{rng.choice(suffixes)}".strip()


def _gen_until(base_pool, target, intent, seen, rng, max_attempts_factor=50):
    """Generate up to `target` unique examples from base_pool with variation."""
    out = []
    attempts = 0
    max_attempts = target * max_attempts_factor
    while len(out) < target and attempts < max_attempts:
        attempts += 1
        base = rng.choice(base_pool)
        text = apply_light_variation(base, rng)
        if text not in seen:
            seen.add(text)
            out.append({"transcript": text, "intent": intent})
    return out


def _gen_until_formatted(patterns, topics, target, intent, seen, rng, max_attempts_factor=50):
    """Generate up to `target` unique examples from pattern×topic combos."""
    out = []
    attempts = 0
    max_attempts = target * max_attempts_factor
    while len(out) < target and attempts < max_attempts:
        attempts += 1
        pattern = rng.choice(patterns)
        n_placeholders = pattern.count("{}")
        if n_placeholders == 1:
            base = pattern.format(rng.choice(topics))
        elif n_placeholders == 2:
            t1, t2 = rng.sample(topics, 2)
            base = pattern.format(t1, t2)
        else:
            continue
        text = apply_light_variation(base, rng)
        if text not in seen:
            seen.add(text)
            out.append({"transcript": text, "intent": intent})
    return out


def generate_supplement_v2():
    rng = random.Random(456)
    examples = []
    seen = set()

    # Unknown with action verbs (non-Mac) — target 12k
    examples.extend(_gen_until(UNKNOWN_NON_MAC_ACTIONS, 12000, "unknown", seen, rng))

    # Unknown without action verbs — target 8k
    examples.extend(_gen_until(UNKNOWN_NO_ACTION, 8000, "unknown", seen, rng))

    # Research with knowledge patterns — target 6k
    examples.extend(_gen_until_formatted(RESEARCH_WITH_KNOWLEDGE_PATTERNS,
                                         RESEARCH_TOPICS_FOR_KNOWLEDGE,
                                         6000, "research", seen, rng))

    # Screen description (clearer) — target 5k
    examples.extend(_gen_until(SCREEN_DESC_CLEAR, 5000, "screenDescription", seen, rng))

    # Pure knowledge (clearer) — target 4k
    examples.extend(_gen_until_formatted(PURE_KNOWLEDGE_CLEAR,
                                         PURE_KNOWLEDGE_TOPICS,
                                         4000, "pureKnowledge", seen, rng))

    rng.shuffle(examples)
    return examples


def main():
    examples = generate_supplement_v2()
    print(f"Generated {len(examples)} supplementary v2 examples")

    counts = Counter(e["intent"] for e in examples)
    for cls, cnt in sorted(counts.items()):
        print(f"  {cls:24s}  {cnt:6d}")

    out_jsonl = OUTPUT_DIR / "supplement-v2.jsonl"
    with out_jsonl.open("w") as f:
        for e in examples:
            f.write(json.dumps(e) + "\n")

    print(f"\nWrote to {out_jsonl}")


if __name__ == "__main__":
    main()
