import 'package:flutter/material.dart';

import 'chrome.dart';

/// A quiet "where I met this word" caption — the capture's source **app** + **window title**
/// (capture provenance). Shown read-only under the sentence on the Review card back and on each
/// Word Book context card; the same warm-library voice both clients build on.
///
/// Returns `null` when there is no source to show, so a caller can omit it entirely (no empty
/// chrome on a context captured before this shipped, or one whose source was cleared in the overlay).
/// The app reads slightly stronger (ink2, w600) than the title (ink3) — the app is the anchor, the
/// title the detail — and the whole line stays on ONE row, ellipsizing a long title.
Widget? captureSourceCaption(
  OnboardingPalette p, {
  String? sourceApp,
  String? sourceTitle,
  double size = 11.5,
}) {
  final app = (sourceApp ?? '').trim();
  final title = (sourceTitle ?? '').trim();
  if (app.isEmpty && title.isEmpty) return null;

  final spans = <InlineSpan>[
    if (app.isNotEmpty)
      TextSpan(
        text: app,
        style: p.chrome(size: size, weight: FontWeight.w600, color: p.ink2),
      ),
    if (app.isNotEmpty && title.isNotEmpty)
      TextSpan(
        text: '  ·  ',
        style: p.chrome(size: size, weight: FontWeight.w400, color: p.ink3),
      ),
    if (title.isNotEmpty)
      TextSpan(
        text: title,
        style: p.chrome(size: size, weight: FontWeight.w400, color: p.ink3),
      ),
  ];

  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Icon(Icons.web_asset_outlined, size: size + 2.5, color: p.ink3),
      ),
      Expanded(
        child: Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}
