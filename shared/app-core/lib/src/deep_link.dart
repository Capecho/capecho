/// Deep-link routing. The widget (and a future notification) open the app via a `capecho://` URL;
/// this parses one into a typed [DeepLinkTarget] the client navigates to. Pure Dart (no plugin) — the
/// client wires `app_links`' incoming-URI stream to [parseDeepLink], then routes.
library;

/// A resolved `capecho://` deep link. `sealed` so a client `switch` is exhaustive.
sealed class DeepLinkTarget {
  const DeepLinkTarget();
}

/// `capecho://review?word=<id>&src=<surface>` — open Review, optionally jumping to a specific word.
/// [source] is attribution (which surface opened it) so the in-app rating that follows can be tagged
/// the same way the widget's own grades are (`widget` | `notification` | …).
class ReviewDeepLink extends DeepLinkTarget {
  const ReviewDeepLink({this.wordId, this.source = 'widget'});

  /// The word to open at, or null to just open Review.
  final String? wordId;

  /// Originating surface (the `src` query param), default `widget`.
  final String source;

  @override
  bool operator ==(Object other) =>
      other is ReviewDeepLink && other.wordId == wordId && other.source == source;

  @override
  int get hashCode => Object.hash(wordId, source);

  @override
  String toString() => 'ReviewDeepLink(word: $wordId, src: $source)';
}

/// Parse a `capecho://` URI into a [DeepLinkTarget], or null if it isn't a link we route (wrong scheme
/// / unknown host). Lenient on the query: a missing/blank `word` → open Review with no jump; a missing
/// `src` → `widget`.
DeepLinkTarget? parseDeepLink(Uri uri) {
  if (uri.scheme != 'capecho') return null;
  switch (uri.host) {
    case 'review':
      final word = uri.queryParameters['word'];
      final src = uri.queryParameters['src'];
      return ReviewDeepLink(
        wordId: (word != null && word.isNotEmpty) ? word : null,
        source: (src != null && src.isNotEmpty) ? src : 'widget',
      );
    default:
      return null;
  }
}
