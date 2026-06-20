import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';

import 'channel_widget_host.dart';

/// Owns the review widget's app-side lifecycle, gluing the shared [WidgetBridge] to the iOS
/// [HomeWidgetHost] + `app_links`:
///  - [publish] a fresh snapshot when due data may have changed (sign-in / app resume);
///  - [onForeground] drains the grades the widget enqueued, then re-publishes (D9-C foreground flush);
///  - [clear] wipes the shared container on sign-out;
///  - [startDeepLinks] routes the widget's `capecho://review?word=…` taps.
///
/// FSRS stays server-authoritative — everything flows through [WidgetBridge], which only produces
/// [SyncEvent]s. Safe on Android (no widget surface): the host calls no-op.
class WidgetSync {
  WidgetSync({required this.api, this.onReviewDeepLink});

  final CapechoApi api;

  /// Invoked when the widget opens the app at a word (the client navigates Review there).
  final void Function(ReviewDeepLink link)? onReviewDeepLink;

  final ChannelWidgetHost _host = const ChannelWidgetHost();
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  WidgetBridge _bridge(String explanationLanguage) => WidgetBridge(
    host: _host,
    builder: WidgetSnapshotBuilder(api: api, explanationLanguage: explanationLanguage),
  );

  /// Begin routing widget deep links (and handle a cold-start link). Call once at startup.
  Future<void> startDeepLinks() async {
    _linkSub = _appLinks.uriLinkStream.listen(_route);
    final initial = await _appLinks.getInitialLink();
    if (initial != null) _route(initial);
  }

  void _route(Uri uri) {
    final target = parseDeepLink(uri);
    if (target is ReviewDeepLink) onReviewDeepLink?.call(target);
  }

  /// Publish a fresh snapshot (signed-in only — the builder needs a session).
  Future<void> publish(String explanationLanguage) => _bridge(explanationLanguage).publish();

  /// App foreground: drain the widget's grades, then re-publish a fresh snapshot.
  Future<void> onForeground(String explanationLanguage) =>
      _bridge(explanationLanguage).onForeground();

  /// Sign-out: wipe the shared container so the next account starts clean.
  Future<void> clear() => _host.clear();

  void dispose() {
    unawaited(_linkSub?.cancel());
  }
}
