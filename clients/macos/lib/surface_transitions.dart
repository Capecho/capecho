import 'package:flutter/material.dart';

/// Page transitions for the windowed surfaces.
///
/// Two kinds, by where a page sits in the stack:
///
/// - [rootSurfaceRoute] — a **root surface** opened straight from the menu bar / global hotkeys
///   (Review · Word Book · Settings · the onboarding replay) over the hidden agent host. It's the
///   "first page", not a navigation step, so it appears **instantly** — no slide-in, and (since the
///   builder ignores `secondaryAnimation`) whatever sits beneath never parallax-slides when a child
///   is pushed on top of it.
///
/// - [nestedSurfaceRoute] — a page pushed **on top of** a surface (Word Book detail, Recently
///   deleted, or the Word Book opened from Settings). It **slides in** from the right while the page
///   beneath stays put (the route below is itself one of these routes, both of which ignore
///   `secondaryAnimation`, so the underlying surface is held fixed — no twin-slide).
///
/// Pages opened with [nestedSurfaceRoute] also show a back button in their [SurfaceHeader]; root
/// surfaces show the brand mark and dismiss via Esc / the window close button instead.

/// Instant, transition-less route for a top-level surface (see file header).
Route<T> rootSurfaceRoute<T>(Widget page) => PageRouteBuilder<T>(
  pageBuilder: (_, _, _) => page,
  transitionDuration: Duration.zero,
  reverseTransitionDuration: Duration.zero,
  // No transitionsBuilder → the default returns the child unchanged, so this route neither
  // animates itself in NOR reacts to a child being pushed over it (the underlying page is fixed).
);

/// Slide-in route for a nested page, leaving the page beneath fixed (see file header).
Route<T> nestedSurfaceRoute<T>(Widget page) => PageRouteBuilder<T>(
  pageBuilder: (_, _, _) => page,
  transitionDuration: const Duration(milliseconds: 260),
  reverseTransitionDuration: const Duration(milliseconds: 220),
  // Only the INCOMING page is animated (off `animation`); `secondaryAnimation` is ignored, so
  // pushing a further page on top of this one won't slide this one away either.
  transitionsBuilder: (_, animation, _, child) {
    final slide = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(
      CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );
    return SlideTransition(position: slide, child: child);
  },
);
