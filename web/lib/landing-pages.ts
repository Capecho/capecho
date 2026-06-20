/**
 * SEO landing-page content model.
 *
 * Slugs, titles, keywords, core messages, and the internal-linking graph drive
 * the SEO surface. Product claims stay aligned with docs/product-definition.md
 * (the source of truth): we lead with context + AI understanding + the
 * capture→echo loop + privacy, and we never headline etymology.
 *
 * CONSOLIDATED to ten canonical pages — one per keyword cluster — after Google
 * flagged the earlier 23-page set as duplicate/thin ("Crawled – currently not
 * indexed"). Each surviving page absorbs the distinct angle and keywords of the
 * near-duplicates it replaced; the retired slugs 301-redirect into their
 * canonical here (see next.config.ts `redirects()`), so inbound signals carry
 * over and no internal link 404s.
 *
 * `related` only references slugs that exist in this file, so internal links
 * never break.
 */
import { siteConfig } from "@/lib/site";

export type LandingSection = {
  heading: string;
  body: string[];
};

export type LandingPage = {
  slug: string;
  eyebrow: string;
  metaTitle: string;
  metaDescription: string;
  h1: string;
  lede: string;
  keywords: string[];
  sections: LandingSection[];
  related: string[];
};

export const landingPages: LandingPage[] = [
// === save-words-in-context ===
{
  slug: "save-words-in-context",
  eyebrow: "Core product",
  metaTitle: "Save Words in Context from Any Screen",
  metaDescription:
    "Save new words together with the sentence where you met them. Capecho captures words from your screen, explains them with AI, and schedules SRS reviews before they fade.",
  h1: "Save words in context, from any screen",
  lede: "Looking up a word helps you understand it once. Saving it with context helps you remember it later.",
  keywords: [
    "save words in context",
    "save new words",
    "save vocabulary words",
    "app to save new words",
  ],
  sections: [
    {
      heading: "The sentence is part of the meaning",
      body: [
        "A word is easier to remember when it stays attached to the sentence, situation, and source where you first met it. Capecho keeps the exact sentence as the context of every saved word, so you review the word the way you actually encountered it, not as an entry on a generic list.",
        "That sentence isn't decoration. It's the cue your memory will reach for later: the topic, the tone, the grammar, and your own recollection of the moment all ride along with it. Strip the sentence away and you're left with a bare word that's attached to nothing.",
      ],
    },
    {
      heading: "The friction that makes you give up on saving words",
      body: [
        "Most people mean to save the words they meet, then don't. The usual workflow is the problem: stop reading, copy the word, switch apps, paste it, hunt down a definition, retype the sentence, format a card. By the time that's done, you've lost both your place and the will to do it again tomorrow.",
        "Capecho removes that tax. While you read on your Mac, one keyboard shortcut grabs the word and the sentence around it and opens a small preview right where you are. There's no second app to switch to and no card to build by hand, so saving a word costs a moment instead of a detour.",
      ],
    },
    {
      heading: "How Capecho captures the word and its sentence",
      body: [
        "Capture runs on macOS's built-in on-device text recognition, the same engine behind Live Text. It reads the word and surrounding sentence only at the instant you press the shortcut and returns just the text — the screen image itself never reaches Capecho. Nothing runs in the background, nothing is uploaded, and your screen is never recorded or streamed.",
        "If you'd rather not point a shortcut at the screen at all, there's a copy-paste mode: copy the passage yourself, press the shortcut, and Capecho reads only what you put on the clipboard. Either way, capture happens because you asked for it, the moment you asked.",
      ],
    },
    {
      heading: "Edit before you save, so the library stays yours",
      body: [
        "The capture preview is a place to edit, not just a confirmation step. If recognition grabbed a stray character, fix the word. If the sentence runs long or includes something private like an email or an account ID, trim or mask it before saving. You decide exactly what enters your vocabulary.",
        "The captured word itself stays fixed once saved, which keeps your records stable. The two surfaces you can always adjust are the context sentence and its gloss, so you can refine how a word is framed without rewriting what you actually met.",
      ],
    },
    {
      heading: "Understanding comes attached, and most of it is free",
      body: [
        "Every saved word carries a word explanation: its core meaning and part of speech, its distinct senses, per-part-of-speech pronunciation, and a handoff to the macOS system Dictionary. That explanation is free and unmetered. It's generated once from the word alone and shared from a public cache, so your own sentence is never part of it.",
        "When you want the word explained as it's used in your specific sentence, that in-context explanation is metered: ten a day, free, with unlimited on Pro. Reaching that limit never blocks capturing, saving, reviewing, or the free word explanation. It only pauses that single feature until the next day.",
      ],
    },
    {
      heading: "From saved word to durable memory",
      body: [
        "Saving is step one. On your Mac, words come back as FSRS spaced-repetition cards fronted by your own sentence with the word in place, surfacing just before you'd forget so a fleeting encounter turns into something that sticks. There's no deck to assemble; capturing already built the card.",
        "Capecho is built first for English, the first target we've quality-validated, but it was never English-only. You can capture, save, and review other languages today, and you can export everything to Anki or CSV at any time, with a target-language column so multi-language decks don't collide. A companion that lets you review on your phone is now on the App Store, so the words you save at your desk return in the small gaps of your day.",
      ],
    },
  ],
  related: [
    "screen-vocabulary-capture",
    "ai-vocabulary-explanation",
    "words-in-context",
    "privacy-first-vocabulary-capture",
  ],
},
// === screen-vocabulary-capture (canonical for capture & OCR; absorbs ocr-vocabulary-app, save-words-from-unselectable-text, screen-translate-to-flashcard) ===
{
  slug: "screen-vocabulary-capture",
  eyebrow: "Capture & OCR",
  metaTitle: "Screen Vocabulary Capture & OCR — Save Words From Any Screen",
  metaDescription:
    "Capture new words from any screen — even video subtitles, scanned PDFs, and images you can't select. One shortcut, on-device OCR, edit, and save without breaking your flow.",
  h1: "Screen vocabulary capture, without breaking your flow",
  lede: "When you stop reading to manually copy a word, you lose focus. Capecho lets you capture the word — even from text you can't select — and keep going.",
  keywords: [
    "screen vocabulary capture",
    "capture words from screen",
    "OCR vocabulary app",
    "save words from images",
    "save words from videos",
    "save words from PDFs",
    "save words from unselectable text",
    "capture words from video subtitles",
    "screen to flashcard",
  ],
  sections: [
    {
      heading: "The interruption is the real cost",
      body: [
        "The hardest part of building vocabulary while reading isn't memory, it's the interruption. Each time you stop to copy a word, switch to another app, and paste it, you spend more attention on logistics than on the sentence in front of you, and the thread of what you were reading frays a little.",
        "Screen vocabulary capture is built to make that cost vanish. One shortcut reads the word and its sentence straight from your screen, and saving takes a single keystroke. Your attention stays on the page, and the act of collecting a word stops competing with the act of reading.",
      ],
    },
    {
      heading: "One shortcut, anywhere on your Mac",
      body: [
        "Capecho lives behind a single global shortcut on macOS, so it doesn't matter which app you're reading in. A browser article, a PDF, a documentation site, a code editor, a paused video frame: press the shortcut and Capecho captures the word and the surrounding sentence wherever you are.",
        "That universality is the point of capturing words from the screen rather than from inside one particular app. You don't go to your vocabulary tool; it comes to whatever you're already reading, and then gets out of the way.",
      ],
    },
    {
      heading: "If you can see the word, you can save it — even unselectable text",
      body: [
        "Video subtitles are the clearest example: a phrase you'd like to keep flashes by and is gone before you can pause and copy it. Save words from videos and the friction disappears, because you're reading pixels, not a transcript you don't have.",
        "Scanned PDFs and image-based course packs are the same story. They look like text but behave like pictures, so highlighting does nothing. The ability to save words from PDFs and save words from images is exactly where an OCR approach earns its place, turning the documents you actually study into a source you can collect from.",
      ],
    },
    {
      heading: "How a capture actually works",
      body: [
        "Capture runs on macOS's built-in on-device text recognition, the engine behind Live Text. It reads the text at the instant you press the shortcut and returns only that text — the screen image itself never reaches Capecho. There's no background scanning and nothing leaves your machine.",
        "macOS asks for a permission it labels Screen Recording to allow this, but that's the operating system's name for the mechanism, not a description of Capecho's behavior. Capecho never records or streams your screen. If you'd rather skip that permission, a copy-paste mode reads only the selection you've copied, and only after you press the shortcut.",
      ],
    },
    {
      heading: "Fast to save, with room to edit",
      body: [
        "Speed and control don't have to trade off. The capture preview is quick by default, but it's a place you can edit before saving: fix a character recognition got wrong, tighten the sentence, or strip out anything you'd rather not keep. You approve what gets saved.",
        "That keeps your library deliberately yours instead of a dump of whatever was on screen. The captured word stays fixed once it's in, while the context sentence and its gloss remain editable, so refining a word later never means re-capturing it.",
      ],
    },
    {
      heading: "It explains the word — it doesn't translate your screen",
      body: [
        "It helps to be exact about what \"screen to flashcard\" means here, because Capecho is not a screen translator. It does not overlay a translated copy of the page or swap the text in front of you. What it does is read the single word or phrase you point at, keep the exact sentence you met it in, and explain that word — its core meaning, part of speech, distinct senses, and pronunciation, plus a handoff to the macOS system Dictionary.",
        "So the flashcard you end up with is built around understanding, not a one-shot translation. The word stays in the language you are learning, the sentence stays intact as your context, and the explanation gives you something to actually remember rather than a substitute to glance at and forget.",
      ],
    },
    {
      heading: "Captured with its context",
      body: [
        "Capecho doesn't just grab the word, it keeps the exact sentence you met it in. That sentence is what makes the word memorable later: when it comes back for review, you recall not only a definition but the moment and the meaning you first attached to it.",
        "Along with the sentence comes a free word explanation, generated from the word alone and shared from a public cache, so your sentence is never part of what's cached. When you want the word explained as used in your specific sentence, that in-context explanation is metered: ten a day, free (unlimited on Pro), and never a blocker for anything else.",
      ],
    },
    {
      heading: "Where the captured words go",
      body: [
        "On your Mac or iPhone, saved words return as FSRS spaced-repetition cards fronted by your own sentence, surfacing right before you'd forget so a quick capture turns into lasting memory, with no deck to build by hand. You can also export anything to Anki or CSV whenever you want, with a target-language column for multi-language decks.",
        "Capecho is built first for English, the first quality-validated target, but you can capture and save other languages now too. A companion for reviewing on your phone is now on the App Store, so the words you capture from the screen at your desk come back during the small gaps in your day.",
      ],
    },
  ],
  related: [
    "save-words-in-context",
    "privacy-first-vocabulary-capture",
    "desktop-vocabulary-app",
    "anki-alternative-for-vocabulary",
  ],
},
// === privacy-first-vocabulary-capture ===
{
  slug: "privacy-first-vocabulary-capture",
  eyebrow: "Privacy & trust",
  metaTitle: "Privacy-first Vocabulary Capture",
  metaDescription:
    "Capecho is built for vocabulary, not data collection. On-device recognition, capture only on your shortcut, edit before saving, and a copy-paste mode.",
  h1: "Privacy-first vocabulary capture",
  lede: "Capecho is built for vocabulary, not data collection. Capture is powerful, so trust is part of the product.",
  keywords: [
    "private vocabulary app",
    "privacy-first vocabulary capture",
    "local OCR vocabulary app",
    "secure vocabulary app",
  ],
  sections: [
    {
      heading: "Powerful capture only earns trust if it's bounded",
      body: [
        "A tool that can capture a word from anything you're reading — even text you can't select — is genuinely useful, and that same power is exactly why its limits have to be clear. A private vocabulary app should be able to tell you precisely when it looks, what it keeps, and what it sends, and the honest answer for Capecho is: only when you ask, only the word and sentence you approve, and as little as possible beyond your own device.",
      ],
    },
    {
      heading: "On-device recognition, only at the instant you press the shortcut",
      body: [
        "Capecho recognizes the text using macOS's built-in, on-device text recognition — the same engine behind Live Text — so the recognition itself happens locally as a local OCR vocabulary app, not on a server. It runs only at the single instant you press the capture shortcut. There is no continuous, background, or scheduled reading of your screen, and the system returns only the recognized text — the screen image itself never reaches Capecho.",
        "macOS gates this kind of capture behind a permission it labels \"Screen Recording,\" and that name can sound alarming. It's just the operating system's mechanism for letting an app read on-screen text on demand; Capecho never records or streams the screen, and never watches it between captures. The permission is the door, and Capecho only opens it for the split second you ask it to.",
      ],
    },
    {
      heading: "You edit before anything is saved",
      body: [
        "Nothing enters your vocabulary library automatically. Every capture opens a preview you can edit, not just confirm: correct a mis-grabbed word, tighten the context sentence, or delete a stray email address, name, or account ID that happened to sit near the word. Only what you approve is saved.",
        "This is the difference between a capture you can trust and one you can't. The word you grabbed is the unit you keep, and the sentence and its gloss are yours to adjust — so a private detail that wandered into frame never has to become a saved card.",
      ],
    },
    {
      heading: "What leaves your device, and what doesn't",
      body: [
        "The free word explanation is generated once from the word alone and shared through a public cache, so your sentence is never part of what builds it. Only when you ask for the meaning of a word as used in your specific sentence does that one sentence get sent to be explained — it's an explicit, per-word action you choose, capped at ten a day, never a background upload. If you'd rather keep more on your machine, you can simply not request that in-context layer; everything else still works.",
      ],
    },
    {
      heading: "A copy-paste mode, by design — not a downgrade",
      body: [
        "If you would rather not grant screen-recognition permission at all, Capecho works in a copy-paste mode: it reads your copied selection only after you press the shortcut, and never monitors the clipboard in the background. This is a deliberate trust feature for a secure vocabulary app, offered as a first-class path, not a crippled fallback — you can build your entire vocabulary this way and never enable screen capture.",
      ],
    },
    {
      heading: "Built for the Mac and iPhone, honest about what's next",
      body: [
        "Capecho's capture and review live in the macOS app, and review also lives in the iPhone app; that's where your library stays, syncing between them. The same privacy posture carries across both — you, not a background process, decide what gets captured and explained. There are no hidden trackers and no data-collection business model underneath; the product is the vocabulary loop, not your screen.",
      ],
    },
  ],
  related: [
    "screen-vocabulary-capture",
    "save-words-in-context",
    "desktop-vocabulary-app",
  ],
},
// === desktop-vocabulary-app ===
{
  slug: "desktop-vocabulary-app",
  eyebrow: "Core product",
  metaTitle: "A Desktop Vocabulary App Built for Real Reading and Watching",
  metaDescription:
    "Most vocabulary apps start inside the app. Capecho starts where you actually meet the word — on your Mac, while you read, study, and watch.",
  h1: "A desktop vocabulary app built for real reading",
  lede: "Most vocabulary apps start inside the app. Capecho starts where you actually meet the word.",
  keywords: [
    "desktop vocabulary app",
    "vocabulary app for desktop",
    "Mac vocabulary app",
    "save words on Mac",
  ],
  sections: [
    {
      heading: "The words worth learning are already on your screen",
      body: [
        "The vocabulary you actually need shows up while you read articles, study PDFs, work through documentation, and watch videos on your computer — not inside a vocabulary app's word list. A desktop vocabulary app meets those words where they appear instead of asking you to remember them and retype them into a separate place later, where most of them quietly never make it.",
      ],
    },
    {
      heading: "One global shortcut, in any app",
      body: [
        "Capecho lives on your Mac as a menu-bar tool behind a single global shortcut, so it's available in whatever you're reading — a browser, a PDF reader, a notes app, a video player. Press the shortcut and it reads just the word and its sentence at that moment, then lets you keep going. There's no switching windows, no leaving your place, and no copy-paste detour through another app.",
        "Because capture is one keystroke, building vocabulary stops competing with reading. You save the word on Mac in the flow of the sentence you're in, and your attention returns to the page immediately.",
      ],
    },
    {
      heading: "It keeps the sentence, not just the word",
      body: [
        "Every capture holds onto the exact sentence you met the word in, because that context is most of what makes a word memorable later. The captured word itself is fixed — the editable surfaces are the context sentence and its gloss — so you can tidy the sentence or adjust the meaning without ever losing the original encounter. When the word comes back to you in review, it arrives in the setting where you first understood it.",
      ],
    },
    {
      heading: "Understanding, not just a definition",
      body: [
        "When you capture a word, Capecho gives you a real explanation rather than a bare translation: its core meaning and part of speech, its distinct senses, pronunciation per part of speech, and a handoff to the macOS system Dictionary if you want to go deeper. That word explanation is free and unmetered. When you want the meaning of the word as it's used in your particular sentence, that in-context explanation is metered — ten a day, free, unlimited on Pro — and reaching the cap never stops you from capturing, saving, or reviewing.",
      ],
    },
    {
      heading: "Capture on the Mac, review on the Mac or iPhone",
      body: [
        "Saved words don't just pile up in a list — they come back as FSRS spaced-repetition reviews, each fronted by your own sentence with the word in place, surfaced just before you'd forget it. There's no manual card-building; capturing a word is what creates the review. Both halves of that loop live in the macOS app, so you can capture and review on the same machine — and review also travels to your iPhone.",
        "A phone companion for reviewing on the go is now on the App Store, so your captures and review history are one library that follows you between your desk and your pocket. And whenever you like, you can export your context-rich cards to Anki or CSV, with a target-language column, since Capecho is a complement to the tools you already trust rather than a replacement for them.",
      ],
    },
    {
      heading: "Built first for English, not English-only",
      body: [
        "Capecho is tuned first for English as its first quality-validated target, but it isn't limited to it: words in other languages can be captured, saved, and reviewed today, and generated explanations expand to more languages as their quality is validated. The core loop — capture, understand, review — is free, with no subscription on it.",
      ],
    },
  ],
  related: [
    "cross-platform-vocabulary-notebook",
    "screen-vocabulary-capture",
    "save-words-in-context",
    "micro-learning-vocabulary-app",
  ],
},
// === cross-platform-vocabulary-notebook (canonical for notebook/tracker/cross-platform; absorbs cross-platform-vocabulary-app, vocabulary-tracker) ===
{
  slug: "cross-platform-vocabulary-notebook",
  eyebrow: "Core product",
  metaTitle: "A Cross-Platform Vocabulary Notebook & Tracker That Keeps the Context",
  metaDescription:
    "A modern vocabulary notebook should store more than words — it should keep the moment each word mattered, and track how well you remember it. Capecho keeps your context-rich notebook on your Mac and your iPhone.",
  h1: "A vocabulary notebook that keeps the context",
  lede: "A modern vocabulary notebook should not just store words. It should store the moment where each word mattered — and track how well you remember it.",
  keywords: [
    "cross-platform vocabulary notebook",
    "vocabulary notebook app",
    "digital vocabulary notebook",
    "vocabulary journal app",
    "cross-platform vocabulary app",
    "sync vocabulary between desktop and mobile",
    "vocabulary tracker",
    "track words encountered",
  ],
  sections: [
    {
      heading: "More than a list of words",
      body: [
        "A paper vocabulary notebook captures words but loses everything around them — the sentence, the source, the reason the word caught your eye. Capecho keeps all of it. Each entry holds the word, the exact sentence you met it in, an explanation of what it means, and a record of how well you remember it. The notebook stores the moment, not just the term.",
        "That context is the difference between a list you skim and a notebook you actually learn from. Read back an entry weeks later and the sentence puts you right back where the word lived.",
      ],
    },
    {
      heading: "Entries you write by reading",
      body: [
        "You fill this notebook the way it should be filled — by reading, not by transcribing. When a word stops you on the Mac, one keypress captures it together with its sentence, opens a preview you can edit, and saves it on confirm. No copying into a separate app, no manual page-keeping.",
        "The captured word stays fixed, but the editable surfaces are the ones that should be: the context sentence and its gloss. You can tidy a sentence or sharpen a definition any time, so the notebook reads cleanly without ever falsifying the word you actually met.",
      ],
    },
    {
      heading: "One notebook, kept in sync",
      body: [
        "The defining feature of a cross-platform notebook is that there is only one of it. Capecho syncs your entries to a single source of truth, so you are never reconciling two half-finished lists. Add a word, refine a sentence, finish a review on your Mac, and it lands in one canonical library — so on the iPhone companion it's the same notebook, not a second list to reconcile.",
        "Review scheduling is server-authoritative too, so an entry's due date is consistent rather than drifting between devices. The notebook doesn't just hold the same words everywhere; it holds the same state.",
      ],
    },
    {
      heading: "See what's settling and what's still due",
      body: [
        "A vocabulary tracker should track more than the words; it should track your grip on them. Capecho schedules each word with FSRS spaced repetition, so every entry also carries a review state — settled into memory, or due to come back soon. A glance across your Word Book tells you which words you have genuinely retained and which still need another pass.",
        "That turns tracking into progress. Instead of guessing whether your vocabulary is growing, you can watch words move from fragile and frequently-due toward stable and rarely-due over time.",
      ],
    },
    {
      heading: "On your Mac and your iPhone",
      body: [
        "The notebook lives on your Mac, where you write entries by capturing and review them as they come due, and on your iPhone, where the same library comes back for review. The syncing library spans both devices — cross-platform isn't a direction, it's here.",
        "The iPhone review companion covers the in-between minutes when reaching for your laptop isn't realistic. Because your notebook already syncs to the cloud, there's nothing to move — your entries and their review history are right there.",
      ],
    },
    {
      heading: "A notebook that reviews itself back to you",
      body: [
        "An ordinary notebook is passive — you have to remember to reopen it. Capecho's notebook brings its own entries back. Saved words return as FSRS spaced-repetition cards fronted by your own sentence, surfacing just before you'd forget them, so the act of keeping the notebook is also the act of remembering what's in it.",
        "You rate each card Forget, Hard, Good, or Easy, and the schedule adjusts. The pages you'd otherwise let gather dust quietly move words into long-term memory.",
      ],
    },
    {
      heading: "Open, exportable, and free to keep",
      body: [
        "A notebook you can't take with you isn't really yours. Capecho exports your context-rich entries to Anki and CSV whenever you want, with a target-language column so a multi-language notebook never collides. Keeping the notebook — capturing, unlimited saving, the explanation on each entry, and FSRS review on the Mac — is free, with no subscription on the core loop; the only optional upgrade is unlimited in-context explanations.",
        "Capecho is built first for English and is never English-only, so the notebook is for whatever language you are reading and learning in — a record of everything you've met, kept in one place and ready to grow.",
      ],
    },
  ],
  related: [
    "desktop-vocabulary-app",
    "micro-learning-vocabulary-app",
    "save-words-in-context",
    "how-to-remember-new-words",
  ],
},
// === ai-vocabulary-explanation (canonical for AI explanation; absorbs ai-word-meaning-in-context, sentence-meaning-explanation) ===
{
  slug: "ai-vocabulary-explanation",
  eyebrow: "AI explanation",
  metaTitle: "AI Vocabulary Explanation: Understand a Word — and Its Sentence — Beyond Translation",
  metaDescription:
    "A translation tells you what a word means now. Capecho's AI explains the word's core meanings, resolves what it means in your sentence, and even explains the whole sentence — then saves it for SRS review.",
  h1: "Understand a word beyond translation",
  lede: "A translation gives you an answer. Capecho explains the word — its major senses and how they connect, what it means in your sentence, and when the sentence itself is the hard part — so a single word becomes a small map you can remember.",
  keywords: [
    "AI vocabulary explanation",
    "AI word explanation",
    "explain word meaning with AI",
    "word meaning beyond translation",
    "AI word meaning in context",
    "what does this word mean in this sentence",
    "AI sentence meaning explanation",
    "explain sentence meaning",
    "understand sentence with AI",
  ],
  sections: [
    {
      heading: "A translation answers; an explanation teaches",
      body: [
        "A translation hands you one equivalent and stops. That is enough to keep reading, but it rarely sticks, because a lone equivalent is a fact with nothing attached to it. An AI word explanation does more work: it lays out the word's major meanings in plain language, names its part of speech, and shows how the senses relate — so you leave understanding the word, not just having matched it to one foreign-language token.",
        "This is the difference between word meaning beyond translation and translation alone. Capecho is not a translator and does not try to be one; it is the layer that explains, so the word arrives as something you can reason about rather than a label you will have forgotten by the next paragraph.",
      ],
    },
    {
      heading: "Why one definition is rarely the whole word",
      body: [
        "Most words worth saving carry several related senses. Think of a word like 'charge' — a fee, an accusation, a rush forward, an electrical state — collapsed by a single translation into whichever sense the translator guessed. Memorize that one and the word breaks the next time it appears differently, because you learned a coincidence, not the word.",
        "Capecho's explanation keeps the few genuinely common senses together and shows how they connect, turning a flat lookup into a small, memorable map. A handful of linked meanings is far easier to recall than one isolated definition, and it means the word still makes sense when you meet it somewhere new.",
      ],
    },
    {
      heading: "What Capecho's free word explanation contains",
      body: [
        "The word explanation is the free, unmetered core of Capecho. It opens with a concise core meaning and the part of speech, and behind a calm expand it carries the word's distinct senses — the noun against the verb, for instance — each with per-part-of-speech pronunciation in IPA. It is a compact, AI-authored explanation, not an exhaustive every-sense dump.",
        "When you do want the full reference — every rare sense, dictionary-style examples — a Dictionary button hands off to your Mac's own system dictionary instead of Capecho rebuilding one. The explanation is written by AI under prompts constrained to authoritative sources rather than invented from thin air, so explaining a word's meaning with AI does not mean trusting made-up facts.",
      ],
    },
    {
      heading: "Why all of this is free: generated once, shared by everyone",
      body: [
        "The meaning of a word is the same for every reader, so Capecho generates each word's explanation once and serves it from a shared public cache. Your own sentence is never part of that cache — the explanation is built from the word alone — which is exactly what lets it stay free and unmetered no matter how much you capture.",
        `There is a separate, metered extra: the in-context explanation, which reads the word as used in your specific sentence (${siteConfig.contextDailyCap} a day, free, unlimited on Pro). It costs per use because it cannot be shared, which is why it is metered. The word explanation itself — meaning, senses, pronunciation, the Dictionary handoff — is free and never counts against any limit; saving words is free and unlimited too, so the in-context explanation is the only thing Pro lifts.`,
      ],
    },
    {
      heading: "What the word means here — resolving the sense in your sentence",
      body: [
        "A word like 'figure' can be a number, a shape, a person of note, or a verb meaning to conclude. The general explanation lists those senses side by side; it cannot tell you which one is live in your sentence, because by design it never looks at your sentence. Choosing the right one is a separate question.",
        "The in-context explanation is the part that answers it. It reads your specific word-and-sentence pair and resolves which sense applies, so an AI contextual vocabulary explanation does the disambiguation your eyes were trying to do — and explains the reasoning rather than leaving you to guess among the options. Because it reads your actual sentence, that sentence is treated as private: it's sent to a third-party AI only at the moment you ask, under a strict no-training policy, never automatically.",
      ],
    },
    {
      heading: "When the sentence itself is the hard part",
      body: [
        "Idioms, dense academic phrasing, and new grammatical constructions can leave a sentence murky even when you recognize every word in it. The blocker is not your vocabulary; it is the way the words combine — a figurative turn, an inverted clause, a reference that assumes context you don't have. A dictionary can't help here, because no single word is the problem.",
        "This is exactly the gap an AI sentence meaning explanation closes. Instead of defining one term, it reads the whole sentence and tells you, in plain language, what it is actually saying — so the meaning clicks before you move on and lose it, and the new word inside it has somewhere to live.",
      ],
    },
    {
      heading: "The explanation travels with the word into review",
      body: [
        "Understanding a word once is not the same as remembering it. In Capecho the explanation is saved alongside the word and the exact sentence you captured it in, so nothing has to be looked up twice.",
        "When the word echoes back as a spaced-repetition review — fronted by your own sentence, scheduled by FSRS — the understanding returns with it. And if you keep your cards elsewhere, Anki and CSV export are available anytime, so the explained, context-rich word is never locked in.",
      ],
    },
    {
      heading: "Built first for English, not only for English",
      body: [
        "Capecho is built first for English and validated there first, but it was never designed to be English-only: the captured unit and your sentence are language-neutral, and glosses render in several languages so you can read a meaning in the language you think in.",
        "Generated word explanations expand to more target languages as each one passes its own quality check, which is a deliberate gate rather than a limit — a word's explanation is shown to every user, so it earns the wider rollout by proving it is accurate first.",
      ],
    },
  ],
  related: [
    "words-in-context",
    "save-words-in-context",
    "micro-learning-vocabulary-app",
    "how-to-remember-new-words",
  ],
},
// === words-in-context (canonical for the "learn / in-context" cluster; absorbs word-meaning-in-context, learn-vocabulary-in-context) ===
{
  slug: "words-in-context",
  eyebrow: "Learn",
  metaTitle: "Words in Context: Meaning, Examples, and How to Learn Them",
  metaDescription:
    "Learning words in context means tying meaning to the sentence and situation you met it in. Here's what it means, how to read meaning from context clues — and how Capecho makes it effortless.",
  h1: "What are words in context?",
  lede: "A word is easier to remember when it is attached to the sentence, situation, and memory where you first met it.",
  keywords: [
    "words in context",
    "words in context definition",
    "words in context examples",
    "what does word in context mean",
    "word meaning in context",
    "defining words in context",
    "finding the meaning of words in context",
    "learn vocabulary in context",
    "context vocabulary learning",
  ],
  sections: [
    {
      heading: "Words in context: a definition",
      body: [
        "Learning words in context means studying a word inside the real sentence and situation where it appears, rather than as an isolated entry paired with a single definition. The words-in-context definition is less about the word itself than about everything around it: the sentence, the topic, the tone, and your own memory of the moment you read it.",
        "So when someone asks what 'word in context' means, the short answer is the difference between memorizing 'tremendous = very large' and remembering the sentence where 'a tremendous relief' taught you the word carries feeling, not just size. The context is not decoration around the meaning; for most words it is part of the meaning.",
      ],
    },
    {
      heading: "Why context makes a word easier to recall",
      body: [
        "An isolated word is hard to retrieve because it is attached to nothing — there is no thread leading back to it. The same word inside a remembered sentence comes with cues: the subject you were reading about, the grammar around it, the feeling of the passage. Any one of those can pull the word back when you need it, which is why context-rich memories are so much more durable than flashcard pairs.",
        "This is also why people often recognize a word perfectly on its familiar card yet blank on it while reading. A card learned in isolation builds recall in one artificial setting; real reading is varied, so the word never quite transfers. Context is what lets recognition cross from the card back to the page.",
      ],
    },
    {
      heading: "Why isolated words don't transfer",
      body: [
        "Drilling a word against a single definition teaches you that one pairing — not the word. In real reading the same word arrives in a different sentence, a different register, sometimes a different sense entirely, and the rote version doesn't follow it there. You recognize the flashcard and blank on the page, which feels like a memory failure but is really a context failure.",
        "Learning vocabulary in context builds the flexible understanding that does transfer. When you meet a word inside a real sentence, you absorb not just a meaning but a usage — how it behaves, what it sits next to, what kind of writing it belongs to — and that is the version your brain can apply the next time the word shows up somewhere new.",
      ],
    },
    {
      heading: "Words in context: examples",
      body: [
        "Consider how the same word shifts across sentences. 'She drew water from the well' and 'the children are well' and 'tears welled up' are three different words wearing one spelling — and only the surrounding words tell them apart. A definition list cannot; the sentence can. These are words-in-context examples in the plainest sense: meaning that exists only in the company the word keeps.",
        "The same is true for tone and register. 'Sick' means ill in one sentence and excellent in another; 'sanction' can permit or punish in the very same paragraph. Read each in context and the sense is obvious. Read the word alone and you are guessing, which is exactly the guessing that makes isolated vocabulary so slippery.",
      ],
    },
    {
      heading: "The clues that point to a word's meaning",
      body: [
        "Context clues come in a few recognizable shapes. A definition or restatement nearby ('the colophon, the note at the end of a book') hands you the meaning directly. A contrast word — 'but', 'unlike', 'whereas' — tells you the unknown term is the opposite of something you do know. An example list lets you infer the category that contains them all.",
        "Tone and topic narrow it further. The same word reads differently in a legal contract than in a text from a friend, and the subject of the passage rules out senses that do not fit. Defining words in context is mostly the discipline of using these signals on purpose instead of skating past them.",
      ],
    },
    {
      heading: "The best word list is the one you met yourself",
      body: [
        "Generic vocabulary lists feel like trivia because they arrive with no context attached — someone else's words, in no particular situation, meaning nothing in particular to you. The words actually worth learning are the ones you met in real content you cared enough to read: an article, a novel, a piece of documentation.",
        "Capecho is built around that idea. You do not pick from a prefabricated list; you curate your own vocabulary simply by reading and capturing the words you meet, each one arriving with the sentence that made it matter. Your reading becomes your word list, which is the most contextual list there is.",
      ],
    },
    {
      heading: "Keeping the context, not just the word",
      body: [
        "Most tools throw the context away — you save 'tremendous' and lose the sentence that taught it to you. Capecho keeps the exact sentence you met the word in, and treats that sentence as the editable part: the captured word stays fixed as you met it, while the context sentence and its gloss are yours to refine. The word is the anchor; the context is the meaning you can shape.",
        "On macOS you capture both at once with a single keypress, using your Mac's built-in on-device text recognition (or a simple copy-paste mode), and edit the preview before saving. The point is not the capture mechanics; it is that the context survives — because a word saved without its context is most of the way back to being an isolated word again.",
      ],
    },
    {
      heading: "Context plus review is what makes it stick",
      body: [
        "Context makes a word understandable in the moment; it does not, on its own, make the word permanent. Memory needs the word to come back, spaced out over time, before each encounter fades. Context and repetition are two halves of the same job.",
        "Capecho keeps the context and schedules the review, so the two reinforce each other: saved words return as FSRS spaced-repetition cards fronted by your own sentence, with the word in its natural setting rather than stripped of it. Understanding in context, recalled in context, just before you would forget — that is how a word read once becomes a word you keep.",
      ],
    },
  ],
  related: [
    "how-to-remember-new-words",
    "advanced-vocabulary-app",
    "ai-vocabulary-explanation",
    "save-words-in-context",
  ],
},
// === how-to-remember-new-words ===
{
  slug: "how-to-remember-new-words",
  eyebrow: "Learn",
  metaTitle: "How to Remember New Words: Context First, AI Explanation, SRS Review",
  metaDescription:
    "You don't forget words because you're bad at memorizing — you forget them because you meet them once and never see them again. Here's the loop that fixes it.",
  h1: "How to remember the new words you read",
  lede: "Context makes vocabulary memorable. AI makes it understandable. SRS makes it stick.",
  keywords: [
    "how to remember new words",
    "retain new vocabulary",
    "remember words from reading",
    "stop forgetting new words",
  ],
  sections: [
    {
      heading: "The real problem is the gap, not your memory",
      body: [
        "You meet a word, understand it for a moment, and never see it again. Days later it's gone — and you blame your memory. But forgetting a word you encountered exactly once is not a defect; it is your brain doing precisely what it should, letting go of information that never proved worth keeping. The forgetting curve isn't a flaw to overcome so much as a signal you have to answer.",
        "So the way to remember words from reading is not harder memorization. It is closing the gap between the first encounter and the second — meeting the word again, on purpose, before it fades. Everything below is about making that second meeting actually happen.",
      ],
    },
    {
      heading: "Why look-it-up-and-move-on fails",
      body: [
        "The usual workflow is to look a word up and keep reading. It feels productive, and it does get you through the sentence — but it builds nothing. The lookup answers the immediate question and then disappears, with no record of the word, no trace of the sentence, and no plan to ever see it again.",
        "Saving the word into a list is better, but only barely, if the list is just words and definitions. A bare entry strips away the one thing that made the word learnable — the sentence you met it in — and turns it into trivia you'll skim past. To retain new vocabulary, you have to keep the context, not just the term.",
      ],
    },
    {
      heading: "Capture it the moment you meet it",
      body: [
        "Words you mean to look up later are words you lose; the sentence is already gone by the time you circle back. Capturing in the moment — with the surrounding sentence attached — is the single most important step, because the context is captured while it's still in front of you.",
        "Capecho makes that one shortcut. Rest your cursor near the word on your Mac and press it; macOS's on-device text recognition reads the word and its sentence, even in subtitles or PDFs you can't select, and returns just the text — the screen image never reaches Capecho. A preview shows the word, your sentence, and a meaning; you edit anything that's off and press Enter to save. There's no copying into another app and no card to build.",
      ],
    },
    {
      heading: "Understand it well enough to be worth keeping",
      body: [
        "A word you saved but never really understood is a word you'll fail to recall. Memory holds onto meaning, so the quality of that first understanding matters as much as the act of saving.",
        "Capecho's free, unmetered word explanation gives you the core meaning and part of speech right in the preview, with distinct senses, pronunciation behind a calm expand, and a handoff to the macOS system dictionary for the full entry. When the specific usage is the puzzle, the optional in-context explanation reads the word as it sits in your sentence — metered, free up to ten a day (unlimited on Pro), and reaching that limit never blocks saving or reviewing anything else.",
      ],
    },
    {
      heading: "Let it come back on a schedule",
      body: [
        "This is the step that actually defeats forgetting. Spaced repetition brings each word back at widening intervals, timed to surface just before you'd lose it — early and often for a shaky word, rarely for one that's settled. Each successful recall pushes the next review further out, so a word you genuinely know stops costing you time.",
        "In Capecho, every saved word becomes an FSRS card fronted by your own sentence with the word highlighted, and you rate it Forget, Hard, Good, or Easy. The schedule adapts to those ratings, so the words you find hard come back sooner and the easy ones fade into the background — no decks to organize, no intervals to set by hand.",
      ],
    },
    {
      heading: "What a review actually looks like — and where",
      body: [
        "A review is short and self-paced: a card shows the sentence you read with the new word highlighted, you try to recall what it means, then rate how well you knew it. It tests recognition in the same kind of context where you'll meet the word for real, which is why it transfers back to reading instead of staying trapped on a flashcard.",
        "Today you do this on your Mac, where you also capture, or on your iPhone — so the words you gathered while reading resurface in the idle minutes of your day. And if you'd rather review in a tool you already trust, Capecho exports your context-rich words to Anki and CSV anytime — it's a complement to the spaced-repetition habit, not a replacement for it. Capture in the moment, understand it well, and let the schedule do the remembering: that's how you stop forgetting new words.",
      ],
    },
  ],
  related: [
    "micro-learning-vocabulary-app",
    "advanced-vocabulary-app",
    "words-in-context",
    "save-words-in-context",
  ],
},
// === advanced-vocabulary-app (the intermediate-to-advanced / B2-C1 beachhead — a corpus-validated gap the rest of the site doesn't address) ===
{
  slug: "advanced-vocabulary-app",
  eyebrow: "For advanced readers",
  metaTitle: "An Advanced Vocabulary App for Readers Past the Beginner Stage",
  metaDescription:
    "At B2–C1, generic vocabulary apps stop helping — the words you still need are rare and scattered across what you read. Capecho builds advanced vocabulary from your own reading, in context, and reviews it so the infrequent words don't fade.",
  h1: "Past the beginner apps? Build the vocabulary you actually read.",
  lede: "At an advanced level, the words worth learning are rare, scattered, and specific to what you read — which is exactly where generic vocabulary apps stop helping.",
  keywords: [
    "advanced vocabulary app",
    "advanced english vocabulary",
    "vocabulary app for advanced learners",
    "B2 C1 vocabulary",
    "vocabulary plateau",
  ],
  sections: [
    {
      heading: "Why vocabulary apps stop helping at B2–C1",
      body: [
        "Once you're past the intermediate stage, most vocabulary apps quietly stop being useful. They're built on frequency lists and beginner curricula — the common few thousand words you already know. The words you still don't know aren't on those lists; they're rarer, more specific, and they show up once, in something particular you happened to read. A generic app can't teach you those, because it has no idea what you read.",
        "The bottleneck has also moved. At this level your grammar is mostly settled and your problem is sheer breadth — not knowing enough words. That isn't a course you can buy your way through; it's a coverage gap that only the reading you actually do can close, one real encounter at a time.",
      ],
    },
    {
      heading: "Advanced vocabulary is massive and infrequent — so don't learn it randomly",
      body: [
        "The pool of words above your level is enormous, and most of them surface rarely. Drilling a generic \"advanced words\" list is mostly wasted effort: you grind terms you might use once a year, if ever, and they fade before they're ever useful. The words worth keeping are the ones you actually hit in real reading — pre-filtered by relevance, because you met them in something you cared enough to read.",
        "Isolation also stops working at this level. A rare word memorized as a bare gloss doesn't transfer to the page, because advanced vocabulary lives in its context — the sentence, the register, the field it belongs to. Learned in context, a word arrives with the cues that let you recognize it next time; learned in a silo, it stays a flashcard you ace and then blank on while reading.",
      ],
    },
    {
      heading: "Your reading is the syllabus",
      body: [
        "Capecho doesn't hand you someone else's list. You build your advanced vocabulary from what you already read — articles, papers, documentation, books, subtitles — by capturing the words that actually stop you. One shortcut on your Mac grabs the word and the exact sentence around it, in any app, even text you can't select, and you keep reading.",
        "There's no word-picker and no daily list, because your reading already picks the words. What accumulates is a vocabulary that's relevant by construction: precisely the words at the edge of your level, in the contexts where they matter to you.",
      ],
    },
    {
      heading: "Understand the nuance, not just a swap",
      body: [
        "At an advanced level you rarely need a word translated — you need to know which of its senses is live in your sentence and what nuance it carries here. Capecho's explanation gives you the core meaning, part of speech, and distinct senses, and when the specific usage is the hard part, an opt-in in-context explanation resolves the exact sense the word takes in your line. A handoff to the macOS system dictionary is there when you want the exhaustive entry.",
        "Translation stays available when you want it; it just isn't the ceiling. The point is to leave understanding the word well enough to use it, not to swap it for one token in your own language and move on.",
      ],
    },
    {
      heading: "Review so the infrequent words don't fade",
      body: [
        "The hard part of advanced vocabulary is exactly that the words are rare: you might not meet one again for months — long after you've forgotten it. Capecho closes that gap by bringing each saved word back as spaced-repetition review, surfaced just before you'd lose it, each card fronted by your own sentence so you rehearse the word the way you actually met it.",
        "Because capturing already built the card, there's nothing to assemble by hand — the single biggest reason advanced learners abandon flashcards. Words you find hard come back sooner; words that settle drift out of the way, so your minutes land on the vocabulary that still needs them.",
      ],
    },
    {
      heading: "Built for the advanced reader, honest about scope",
      body: [
        "Capecho is built first for English — its first quality-validated target — but it was never English-only: words in other languages can be captured, saved, and reviewed today, and generated explanations expand as each language passes its quality check. The whole loop — capture, understand, review — is free, with no subscription on what you do every day, and your context-rich words export to Anki or CSV anytime.",
        "It's a complement to the reading you already do and the tools you already trust, not a course that replaces them. The promise is narrow and honest: turn the rare, scattered words you meet at an advanced level into vocabulary you keep.",
      ],
    },
  ],
  related: [
    "words-in-context",
    "how-to-remember-new-words",
    "save-words-in-context",
    "anki-alternative-for-vocabulary",
  ],
},
// === micro-learning-vocabulary-app (canonical for SRS/review; URL kept because indexed, retargeted to the stronger SRS head term; absorbs srs-vocabulary-app, review-words-on-the-go) ===
{
  slug: "micro-learning-vocabulary-app",
  eyebrow: "Review & SRS",
  metaTitle: "SRS Vocabulary App: Spaced-Repetition Review for Words You Meet",
  metaDescription:
    "Capecho turns the words you capture into FSRS spaced-repetition reviews — each card starting from your own sentence, sized to fit the small gaps of your day, so words stick without the slog.",
  h1: "Spaced-repetition review for the words you actually meet",
  lede: "Spaced repetition works best when each card starts from real context — and when review fits the small gaps of your day. Capecho does both.",
  keywords: [
    "SRS vocabulary app",
    "spaced repetition vocabulary app",
    "vocabulary SRS",
    "review vocabulary before forgetting",
    "micro-learning vocabulary app",
    "short vocabulary review",
    "daily vocabulary review app",
    "review vocabulary on the go",
    "mobile vocabulary review",
  ],
  sections: [
    {
      heading: "Spaced repetition, without the busywork",
      body: [
        "Spaced repetition is the most reliable way to remember more in less time: instead of cramming, you meet each word again at widening intervals, right at the edge of forgetting. The catch has always been card creation. Sitting down to type out words, definitions, and example sentences is the chore that quietly kills most people's review habit before it starts.",
        "Capecho removes that step entirely. Every word you capture while reading is already a review card, complete with the sentence you met it in and a free explanation of what it means. There is no manual card-building, no formatting, no separate authoring session — the words arrive ready to review.",
      ],
    },
    {
      heading: "Small sessions beat long ones",
      body: [
        "A few cards while the kettle boils. A minute before a meeting starts. Micro-learning works because it lowers the cost of starting to almost nothing — and a review you'll actually begin beats a thorough study block you keep postponing. The hard part of remembering vocabulary was never the effort of any single review; it was the consistency, and short sessions are what make consistency survivable.",
        "Memory fades on a curve, and the way to interrupt that curve is to meet a word again just before it slips — not to grind it twenty times in one sitting. Cramming feels productive and decays fast; brief reviews spread across days are what move a word into long-term memory. The spacing is doing the work, not the duration.",
      ],
    },
    {
      heading: "How FSRS decides when a word comes back",
      body: [
        "Capecho schedules reviews with FSRS, a modern spaced-repetition algorithm that models how memory actually decays. After each card you rate it Forget, Hard, Good, or Easy, and FSRS uses that signal to predict when you would next be on the verge of forgetting — then surfaces the word just before that point. Words you find hard come back sooner; words you know well drift further out, so your time lands where it does the most good.",
        "The scheduling is server-authoritative, which means a single source of truth governs when every word is due. As your library follows you across devices, the timing stays consistent rather than drifting out of sync.",
      ],
    },
    {
      heading: "Each card is ready the moment you sit down",
      body: [
        "Micro-learning only works if there's zero setup — the instant a review turns into a chore, the small gap closes and you reach for your phone instead. The friction can't live at the start of the session.",
        "In Capecho there is no setup, because every card was already built when you captured the word. Each one carries the exact sentence you met it in, with the word highlighted, plus its free explanation — core meaning, part of speech, distinct senses, and pronunciation. Nothing to format, no deck to assemble; you open it and the words that are due are simply there, fronted by the context that makes them recallable.",
      ],
    },
    {
      heading: "A short review, start to finish",
      body: [
        "Here's the whole loop of one review: a card shows your sentence with the new word highlighted, you try to recall what it means, then you rate how it went — Forget, Hard, Good, or Easy. That's it. The whole thing takes seconds, and because the card starts from real context, you're practicing recognition the way you'll actually meet the word again.",
        "Your rating feeds the schedule. Words you find shaky come back soon; words you know well drift further out and stop taking your time. The system spends your minutes on the words that need them, which is what keeps a short vocabulary review genuinely short.",
      ],
    },
    {
      heading: "Capture and review on the Mac — phone review on the go, now on the App Store",
      body: [
        "The whole loop lives on your Mac. You capture words from whatever you are reading, Capecho explains and saves them, and the same app brings them back as FSRS reviews when they come due — capture and review in one place, no second device required to get value today.",
        "A phone review companion is now on the App Store too, built for exactly those in-between minutes — the commute, the queue, the minute before bed — when you'd otherwise be scrolling. Your words and review history already sync to the cloud, so the queue you've been building on the Mac is there waiting on your iPhone, due dates intact, with nothing to migrate or rebuild.",
      ],
    },
    {
      heading: "Free at the core, open by export",
      body: [
        "The core loop is free and unmetered: capture, unlimited saving, the full word explanation, your Word Book, and FSRS review all cost nothing, with no subscription on the core loop — Pro is the optional upgrade for unlimited in-context. The one metered piece on Free is the optional in-context explanation — the word as used in your sentence — free up to ten a day, and reaching that limit never blocks a single review.",
        "And none of it locks you in. Capecho is a complement to the spaced-repetition tools you may already love, not a wall around your words; export to Anki or CSV anytime. Built first for English and never English-only, it exists to make the remembering as light as the reading — a few words, in a few minutes, whenever you have them.",
      ],
    },
  ],
  related: [
    "how-to-remember-new-words",
    "cross-platform-vocabulary-notebook",
    "anki-alternative-for-vocabulary",
    "desktop-vocabulary-app",
  ],
},
// === anki-alternative-for-vocabulary (canonical for the Anki cluster; absorbs anki-words-in-context, anki-vocabulary-workflow) ===
{
  slug: "anki-alternative-for-vocabulary",
  eyebrow: "Anki workflow",
  metaTitle: "An Anki Alternative for Vocabulary Learners Who Want Less Manual Work",
  metaDescription:
    "Love spaced review but hate building cards by hand? Capecho is lighter, more contextual, and built around capture — with a clean export path to Anki if you want it.",
  h1: "An Anki alternative built around capture",
  lede: "If you love the idea of spaced review but hate building cards by hand, Capecho is built for your workflow.",
  keywords: [
    "Anki alternative for vocabulary",
    "Anki alternative for language learning",
    "flashcard app with context",
    "why I remember words in Anki but not reading",
    "Anki cards with context",
    "Anki words in context",
    "Anki vocabulary workflow",
    "make Anki cards from reading",
  ],
  sections: [
    {
      heading: "Who this is actually for",
      body: [
        "Anki is deep, configurable, and beloved for good reason — if you enjoy tuning intervals and grooming a deck, nothing here is trying to talk you out of it. Capecho is for the other learner: the one who believes in spaced review but stalls at the manual card-building, and whose decks fill with bare word-and-definition entries because making richer ones by hand is too much work to sustain.",
        "If that is you, the realistic outcome with a build-it-yourself flashcard tool is a backlog of words you meant to add and a deck thinner than your reading deserves. Capecho is shaped around removing that exact friction, so the cards get made because making them costs almost nothing.",
      ],
    },
    {
      heading: "Why you recognize words in Anki but blank while reading",
      body: [
        "It is a familiar frustration: the card flips, you answer it instantly, your retention stats look excellent — and then the same word stops you cold in an article a week later. Spaced repetition is doing its job, but a bare word-and-definition card trains recall in one fixed, artificial setting. You learn to recognize the prompt, not to recognize the word in the wild.",
        "Reading is the opposite of fixed. The word arrives mid-sentence, in a tense or a sense you did not drill, surrounded by phrasing you have never seen. None of the cues your card relied on are there, so the recognition that felt solid in Anki simply does not transfer to the page. Cards built from a real sentence carry the grammar, the collocations, and the register that a definition strips away — the cues your brain actually reaches for when the word reappears.",
      ],
    },
    {
      heading: "Same proven engine, less manual work",
      body: [
        "Choosing a different home for review should not mean giving up the science. Capecho schedules with FSRS — the same spaced-repetition algorithm Anki offers — so you keep the retention benefit of well-timed reviews. What changes is the labor in front of it: the cards are not yours to build, because capture builds them for you.",
        "That is the whole trade. You are not swapping a strong algorithm for a weaker one; you are swapping a manual card-building chore for a one-keystroke capture, and letting the proven scheduler do what it already does well.",
      ],
    },
    {
      heading: "Capture replaces the build step",
      body: [
        "On your Mac, a single shortcut captures the word and the exact sentence you met it in, using macOS's built-in on-device text recognition — the engine behind Live Text — and only at the instant you press it. The system returns only the recognized text — the screen image never reaches Capecho — nothing is uploaded, and nothing runs in the background; a copy-and-paste mode covers anywhere you would rather not use screen recognition.",
        "Each capture opens a preview you can edit before saving, so you fix a misread character or trim the sentence on the spot. The card that results is fronted by your own sentence rather than a generic prompt — context-rich by default, with no fields to fill.",
      ],
    },
    {
      heading: "Context and understanding come standard",
      body: [
        "Where a from-scratch flashcard app gives you an empty card, Capecho fills it. Every saved word carries a free, unmetered explanation — senses, part of speech, pronunciation, and a system-dictionary handoff — and review tests the word inside your sentence, so recall transfers back to real reading instead of to a single memorized pairing.",
        "When a sentence is genuinely tricky, an in-context explanation can unpack the precise sense the word carries there. It is metered — ten a day, free, unlimited on Pro — and the cap never blocks capture, the core explanation, review, or export. Built first for English and never English-only, Capecho lets the target language ride along with each word.",
      ],
    },
    {
      heading: "Not a lock-in — keep your Anki deck",
      body: [
        "Picking Capecho is not a wall around your words. Export to Anki and CSV anytime, with a target-language column so a Spanish deck and a German deck stay separate on import, and keep reviewing in Anki if that is your home. Capecho is a complement, not a replacement — you can run both and let it carry only the capture.",
        "And it is honest about where it is today. The core loop — capture, unlimited saving, context, the word explanation, and review on the Mac — is free, with no subscription on the core loop; Pro is the optional paid upgrade for unlimited in-context. The macOS app and an iPhone review companion are both shipped now, so the words you capture today are ready and waiting when review moves to your pocket.",
      ],
    },
  ],
  related: [
    "micro-learning-vocabulary-app",
    "screen-vocabulary-capture",
    "save-words-in-context",
    "ai-vocabulary-explanation",
  ],
},
];

export function getLandingPage(slug: string): LandingPage | undefined {
  return landingPages.find((p) => p.slug === slug);
}

export function landingSlugs(): string[] {
  return landingPages.map((p) => p.slug);
}
