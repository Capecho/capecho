/// Target-profile pronunciation DISPLAY rules — the Dart mirror of
/// `shared/lang`'s `TargetGenerationProfile.pronunciationLabels` (keep the two in sync;
/// the TS side is the contract of record). The blob's pronunciation fields are
/// target-neutral (`pronunciationPrimary` / `pronunciationSecondary`); what they MEAN —
/// "US"/"UK" IPA for English, unlabeled pinyin for Simplified Chinese — is the target
/// profile's call, so labels and decoration are computed HERE and never hard-coded in a
/// renderer (Dart or native; the overlay bridge carries pre-formatted display parts).
library;

/// How one pronunciation slot displays: an optional [label] chip-text ("US"), and
/// whether the bare transcription is wrapped in slashes ([slashed] — the IPA
/// convention; pinyin/kana are not slashed).
class PronunciationSlotStyle {
  final String? label;
  final bool slashed;

  const PronunciationSlotStyle({required this.label, required this.slashed});

  /// The display form of a bare transcription under this style ("/ˈɑbdʒɛkt/", "xíng").
  String format(String value) => slashed ? '/$value/' : value;
}

/// The two slots' styles for one target language.
class PronunciationDisplayProfile {
  final PronunciationSlotStyle primary;
  final PronunciationSlotStyle secondary;

  const PronunciationDisplayProfile({required this.primary, required this.secondary});

  /// The display profile for a target tag. English (any region) = labeled US/UK IPA in
  /// slashes; Chinese = unlabeled, unslashed pinyin; any other/unknown target degrades to
  /// unlabeled, unslashed plain text (safe — only profile-enabled targets ever carry data).
  static PronunciationDisplayProfile forTarget(String targetLanguage) {
    final primarySubtag = targetLanguage.trim().toLowerCase().split('-').first;
    switch (primarySubtag) {
      case 'en':
        return const PronunciationDisplayProfile(
          primary: PronunciationSlotStyle(label: 'US', slashed: true),
          secondary: PronunciationSlotStyle(label: 'UK', slashed: true),
        );
      case 'zh':
        return const PronunciationDisplayProfile(
          primary: PronunciationSlotStyle(label: null, slashed: false),
          secondary: PronunciationSlotStyle(label: null, slashed: false),
        );
      default:
        return const PronunciationDisplayProfile(
          primary: PronunciationSlotStyle(label: null, slashed: false),
          secondary: PronunciationSlotStyle(label: null, slashed: false),
        );
    }
  }
}

/// One renderable pronunciation part: its profile [label] (null = unlabeled) and the
/// already-decorated [display] text. What every surface (Dart text spans, the native
/// overlay bridge) consumes — the value is pre-formatted so no renderer re-implements
/// slash/label policy.
class PronunciationPart {
  final String? label;
  final String display;

  const PronunciationPart({required this.label, required this.display});
}

/// The renderable parts for one reading's two slots under [targetLanguage] — empty slots
/// (omit-on-failed, or a target with no second slot) are skipped.
List<PronunciationPart> pronunciationParts({
  required String targetLanguage,
  required String primary,
  required String secondary,
}) {
  final profile = PronunciationDisplayProfile.forTarget(targetLanguage);
  return [
    if (primary.isNotEmpty)
      PronunciationPart(label: profile.primary.label, display: profile.primary.format(primary)),
    if (secondary.isNotEmpty)
      PronunciationPart(
        label: profile.secondary.label,
        display: profile.secondary.format(secondary),
      ),
  ];
}
