/// The native / explanation languages Capecho can gloss words into — the allowlist mirrored from
/// shared/lang's EXPLANATION_LANGUAGES. The server is authoritative on the value actually used (it
/// re-resolves whatever the client sends); this list is the client-side picker source + default seed,
/// kept here so both clients and onboarding share ONE list (DRY — replaces the per-client hardcoded
/// copies).
const List<String> explanationLanguages = [
  'en',
  'es',
  'de',
  'it',
  'fr',
  'pt',
  'zh-Hans',
  'ja',
  'ko',
];

/// The LEARNING (capture-target) languages — mirrors shared/lang's generation-ENABLED targets (the
/// TargetGenerationProfile registry's `enabled` set: en + zh-Hans + ja). A target outside this set is
/// still saveable + reviewable, but gets no explanations (the server returns `language_unsupported`), so
/// offering it as a learning choice would onboard the user into a broken core loop. ONE list for
/// onboarding + both Settings screens (DRY — replaces the per-client hardcoded copies). Extend ONLY when
/// a new target passes its paid eval gate (docs/adding-a-target-language.md), in lockstep with flipping
/// that profile's `enabled: true` server-side.
const List<String> learningLanguages = ['en', 'zh-Hans', 'ja'];

/// Resolve an OS locale tag (e.g. "zh-Hans-CN", "zh_CN", "en-US", "pt-BR") to the best native
/// (explanation) language on [explanationLanguages], English when nothing matches. Used to seed the
/// default "Native language" on first run so most users need zero config — a Chinese-locale Mac lands
/// on 中文 without touching Settings. Only a sensible default is needed, not byte-parity with the
/// server's resolver, because the server re-resolves the tag the client ultimately sends.
String resolveNativeLanguage(String localeTag) {
  final lower = localeTag.toLowerCase().replaceAll('_', '-');
  final parts = lower.split('-').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return 'en';
  final primary = parts.first;
  // Chinese: only Simplified is on the allowlist; map every zh-* (incl. Traditional/regional) to it —
  // closer for a Chinese reader than the English fallback.
  if (primary == 'zh') return 'zh-Hans';
  const direct = {'en', 'es', 'de', 'it', 'fr', 'pt', 'ja', 'ko'};
  if (direct.contains(primary)) return primary;
  return 'en';
}
