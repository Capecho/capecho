// Capecho language handling — BCP-47 canonicalization + validation + the
// target-generation profile registry (the explanation-generation allowlist) +
// the explanation-language set. (spec §9 / §11 / §13)
//
// Canonicalization is SERVER-AUTHORITATIVE: the server honors the user's explicit
// selection but never trusts an arbitrary client string (zh-hans → zh-Hans, EN → en,
// malformed / pure-private-use rejected). Clients source target_language from the
// canonical onboarding picker; the server canonicalizes + validates on sync and
// re-keys if the client used a non-canonical tag — the same provisional-client /
// authoritative-server pattern the dedup key uses.
//
// Uses the platform Intl canonicalizer (Layer 1 — don't hand-roll BCP-47).

/**
 * Canonicalize a BCP-47 tag. Returns the canonical form, or `null` if the tag is
 * malformed/structurally-invalid or a pure private-use tag (which can't anchor a
 * stable dedup/cache key).
 */
export function canonicalizeBcp47(tag: string): string | null {
  if (typeof tag !== "string") return null;
  const trimmed = tag.trim();
  if (trimmed.length === 0) return null;
  let canonical: string;
  try {
    const out = Intl.getCanonicalLocales(trimmed);
    if (out.length !== 1) return null;
    canonical = out[0]!;
  } catch {
    return null; // RangeError on structurally-invalid tags
  }
  if (/^x(-|$)/i.test(canonical)) return null; // reject pure private-use
  return canonical;
}

export function isValidTargetLanguage(tag: string): boolean {
  return canonicalizeBcp47(tag) !== null;
}

/** Primary (language) subtag of a canonical tag, lowercased. */
export function primarySubtag(canonicalTag: string): string {
  return canonicalTag.split("-")[0]!.toLowerCase();
}

/** True if any subtag is a single char (an extension/private-use singleton: -x-, -u-, -t-, …). */
function hasSingletonSubtag(canonicalTag: string): boolean {
  return canonicalTag.split("-").some((s) => s.length === 1);
}

// --- Language display names (prompt axis) -------------------------------------
// Human-readable names for PROMPTS — a model told "written in de" produces weaker
// output than "written in German", and a wrong-language gloss would be cached under
// the per-language cache key. Must cover EXPLANATION_LANGUAGES and every target
// profile's tag; unlisted tags fall through to the raw tag (a deliberate tell in
// eval output rather than a hard failure).
const LANGUAGE_PROMPT_NAMES: Record<string, string> = {
  en: "English",
  es: "Spanish",
  de: "German",
  it: "Italian",
  fr: "French",
  pt: "Portuguese",
  "zh-Hans": "Simplified Chinese",
  ja: "Japanese",
  ko: "Korean",
};

export function languagePromptName(tag: string): string {
  return LANGUAGE_PROMPT_NAMES[tag] ?? tag;
}

// --- Parts of speech (closed label set) ----------------------------------------
// The ONE closed set of word-class labels the word layer may carry — short ENGLISH
// labels whatever the explanation language (structured metadata, localizable
// client-side later precisely BECAUSE the set is closed). Validation drops any label
// outside this union; each target profile narrows it to the subset that makes sense
// for that language (e.g. "measure word" is zh-only, "phrasal verb" en-only).
export const POS_LABELS = [
  "noun",
  "verb",
  "adjective",
  "adverb",
  "pronoun",
  "preposition",
  "conjunction",
  "interjection",
  "determiner",
  "particle",
  "measure word",
  "phrasal verb",
  "idiom",
  "phrase",
] as const;
export type PosLabel = (typeof POS_LABELS)[number];
export const POS_LABEL_SET: ReadonlySet<string> = new Set(POS_LABELS);

// --- Target-GENERATION profiles (the free word-level layer) --------------------
// One profile per language the word layer can EXPLAIN (the target axis). The profile
// is the language's identity + gating + display contract; the model-facing prompt /
// schema text per target lives with the provider (backend/src/providers) keyed by
// `tag`. The gate is server-authoritative: a target without an ENABLED profile is
// saved + reviewable but returns `language_unsupported` — generation is refused even
// if a client requests it (the anonymous device id is forgeable).
//
// `enabled` flips ONLY behind that language's paid eval gate
// (docs/multilingual-explanations.md — zh-Hans pends Phase D5).
export interface TargetGenerationProfile {
  /** Canonical generation tag — THE word-cache-key tag for this profile. Tags with a
   *  script subtag (zh-Hans) keep the script axis: zh-Hans and zh-Hant must never
   *  collide; region-only variants (en-US/en-GB) collapse to the profile tag. */
  tag: string;
  /** Human-readable name for prompts ("English", "Simplified Chinese"). */
  promptName: string;
  /** Generation allowed? A defined-but-disabled profile resolves (so keying/lookup
   *  logic is testable now) but never generates until its eval gate passes. */
  enabled: boolean;
  /** The POS labels this target may use — a subset of POS_LABELS (schema-enum'd). */
  posLabels: readonly PosLabel[];
  /** Display labels for the two pronunciation slots (null = unlabeled). Mirrored by
   *  the Dart display layer (shared/app-core) — keep in sync. */
  pronunciationLabels: { primary: string | null; secondary: string | null };
  /** Whether this target has a second pronunciation slot at all (en: US+UK). When
   *  false the generation schema omits the field and validation defaults it to "". */
  hasSecondaryPronunciation: boolean;
}

const EN_PROFILE: TargetGenerationProfile = {
  tag: "en",
  promptName: "English",
  enabled: true,
  posLabels: [
    "noun",
    "verb",
    "adjective",
    "adverb",
    "pronoun",
    "preposition",
    "conjunction",
    "interjection",
    "determiner",
    "phrasal verb",
    "idiom",
    "phrase",
  ],
  pronunciationLabels: { primary: "US", secondary: "UK" },
  hasSecondaryPronunciation: true,
};

const ZH_HANS_PROFILE: TargetGenerationProfile = {
  tag: "zh-Hans",
  promptName: "Simplified Chinese",
  enabled: true, // D5 flip (2026-06-12): all three zh gates PASS — word zh-gloss 100/…/95.2, word en-gloss all 100, context 100/91.7/91.7 (eval/out reports, PR #130)
  posLabels: [
    "noun",
    "verb",
    "adjective",
    "adverb",
    "pronoun",
    "preposition",
    "conjunction",
    "interjection",
    "particle",
    "measure word",
    "idiom",
    "phrase",
  ],
  pronunciationLabels: { primary: null, secondary: null }, // pinyin is unlabeled
  hasSecondaryPronunciation: false,
};

// Ships DISABLED until its paid eval gate (the en/zh-Hans pattern — docs/adding-a-target-language.md).
// Japanese POS subset: keeps `particle` (助詞) and `measure word` (助数詞/counter); drops `preposition`
// (Japanese is postpositional — particles cover it), `determiner`, and the English-only `phrasal verb`.
// The pronunciation is the kana furigana reading (no romaji), unlabeled like pinyin; no second slot.
const JA_PROFILE: TargetGenerationProfile = {
  tag: "ja",
  promptName: "Japanese",
  enabled: true, // ja gate PASS (2026-06-18): word ja→ja 100/100/96/100/92/100 & ja→en 100/100/96/100/100/100, context occ 100 / logic 90 (eval/out reports) — generates alongside en + zh-Hans
  posLabels: [
    "noun",
    "verb",
    "adjective",
    "adverb",
    "pronoun",
    "conjunction",
    "interjection",
    "particle",
    "measure word",
    "idiom",
    "phrase",
  ],
  pronunciationLabels: { primary: null, secondary: null }, // kana reading is unlabeled
  hasSecondaryPronunciation: false,
};

export const TARGET_GENERATION_PROFILES: readonly TargetGenerationProfile[] = [
  EN_PROFILE,
  ZH_HANS_PROFILE,
  JA_PROFILE,
];

// Lookup keys: the profile's own tag, matched after likely-subtags maximization —
// first `language-Script` (script-sensitive profiles), then bare `language`
// (region-collapsing profiles). NO bare "zh" entry exists, so zh-Hant maximizes to
// zh-Hant-TW, misses "zh-Hant", misses "zh", and resolves null — the script axis
// can't collapse.
const PROFILES_BY_KEY: ReadonlyMap<string, TargetGenerationProfile> = new Map(
  TARGET_GENERATION_PROFILES.map((p) => [p.tag, p]),
);

/**
 * Resolve a raw client target tag to its generation profile — canonicalize, reject
 * extension/private-use singletons, maximize likely subtags, then match
 * `language-Script` before bare `language`. Returns the profile whether or not it is
 * `enabled` (resolution ≠ gating; gating reads `.enabled`), or `null` when no profile
 * covers the tag.
 */
export function resolveTargetProfile(tag: string): TargetGenerationProfile | null {
  const c = canonicalizeBcp47(tag);
  if (c === null) return null;
  if (hasSingletonSubtag(c)) return null; // no generation for extension/private-use tags
  let loc: Intl.Locale;
  try {
    loc = new Intl.Locale(c).maximize(); // en → en-Latn-US, zh-CN → zh-Hans-CN
  } catch {
    return null;
  }
  const byScript = loc.script ? PROFILES_BY_KEY.get(`${loc.language}-${loc.script}`) : undefined;
  return byScript ?? PROFILES_BY_KEY.get(loc.language) ?? null;
}

export function isGenerationAllowed(tag: string): boolean {
  return resolveTargetProfile(tag)?.enabled === true;
}

/** The ENABLED generation tags. Informational (the registry coverage test reads it; docs cite it) —
 *  runtime gating goes through isGenerationAllowed/resolveTargetProfile, never this set directly. */
export const GENERATION_ALLOWLIST: ReadonlySet<string> = new Set(
  TARGET_GENERATION_PROFILES.filter((p) => p.enabled).map((p) => p.tag),
);

/**
 * Finite generation cache key for an allowlisted target: the resolved profile's own
 * tag. Collapses region/variant tags (en / en-US / en-GB / en-Cyrl … → "en") so the
 * SHARED explanation cache keyspace (and AI spend) stays bounded — a free-layer cost
 * guard (Codex M0b) — while script-sensitive profiles keep the script axis
 * (zh-Hans never collapses toward zh-Hant or bare zh). Returns null if the target
 * isn't generation-allowed.
 */
export function generationCacheKey(tag: string): string | null {
  const p = resolveTargetProfile(tag);
  return p !== null && p.enabled ? p.tag : null;
}

// --- Explanation-LANGUAGE set (the native gloss axis, §9) ---------------------
// The gloss-OUTPUT languages (what a meaning is rendered IN), aligned with the
// learning-language set so a user's "explanation defaults to my learning language"
// is always satisfiable and a non-native speaker can read meanings in their own
// language. Region/locale tags resolve via likely-subtags: en-US→en, es-MX→es,
// pt-BR→pt, zh-CN/zh-SG/bare-zh→zh-Hans. Traditional Chinese (zh-Hant / zh-TW) is
// NOT supported yet (separate generation + normalization work). This is the gloss
// axis only — which TARGET languages get a generated explanation is the separate
// target-generation profile registry above (en, zh-Hans, and ja are enabled).
export const EXPLANATION_LANGUAGES = [
  "en",
  "es",
  "de",
  "it",
  "fr",
  "pt",
  "zh-Hans",
  "ja",
  "ko",
] as const;
export type ExplanationLanguage = (typeof EXPLANATION_LANGUAGES)[number];

// The members that are bare primary-subtag languages (everything except the
// script-qualified Chinese variant) — region/locale tags resolve to these via
// likely-subtags (de-AT → de, pt-BR → pt, ja-JP → ja).
const EXPLANATION_PRIMARY_LANGUAGES: ReadonlySet<string> = new Set(
  EXPLANATION_LANGUAGES.filter((t) => !t.includes("-")),
);

export function resolveExplanationLanguage(tag: string): ExplanationLanguage | null {
  const c = canonicalizeBcp47(tag);
  if (c === null) return null;
  if ((EXPLANATION_LANGUAGES as readonly string[]).includes(c)) return c as ExplanationLanguage;
  let loc: Intl.Locale;
  try {
    loc = new Intl.Locale(c).maximize(); // adds likely subtags: de-AT -> de-Latn-AT, zh-CN -> zh-Hans-CN
  } catch {
    return null;
  }
  // Simplified Chinese is the only script-qualified member; Traditional (zh-Hant) is not supported.
  if (loc.language === "zh") return loc.script === "Hans" ? "zh-Hans" : null;
  // Every other member is a bare primary-subtag language (so region/locale tags resolve to it).
  return EXPLANATION_PRIMARY_LANGUAGES.has(loc.language)
    ? (loc.language as ExplanationLanguage)
    : null;
}

/**
 * The EFFECTIVE gloss language for an account. When [followsLearning] is set the
 * gloss follows the user's learning language (the *immersion* default — an English
 * word explained in English), resolved to a supported gloss language and falling
 * back to "en" when the learning language is unset or isn't itself a supported gloss
 * language. Otherwise it's the user's explicit [explanationLanguage] (a native-language
 * gloss). This is the single source of truth for "which language is a meaning rendered
 * in", computed server-side so every client just reads the resolved value.
 */
export function effectiveExplanationLanguage(
  followsLearning: boolean,
  explanationLanguage: string,
  learningLanguage: string | null,
): ExplanationLanguage {
  if (followsLearning) {
    const followed = learningLanguage ? resolveExplanationLanguage(learningLanguage) : null;
    return followed ?? "en";
  }
  return resolveExplanationLanguage(explanationLanguage) ?? "en";
}

export function isSupportedExplanationLanguage(tag: string): boolean {
  return resolveExplanationLanguage(tag) !== null;
}
