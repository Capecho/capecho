//
//  UnitSpanResolver.swift
//  capture_native
//
//  The captured-span resolver — pure logic, separated for testability.
//  Extracted from CaptureNativePlugin (where it was a `private static` method)
//  so the contract can be exercised by a Flutter-free Swift test target
//  (../../capture_native_logic) without dragging in FlutterMacOS. Foundation-
//  only; the plugin's `overlaySave` calls `UnitSpanResolver.span(...)`.
//

import Foundation

// MARK: - Captured unit span (pure logic, separated for testability)

enum UnitSpanResolver {
  /// UTF-16 `[start, end)` of [unit] within [context] — the case-insensitive
  /// match, mirroring the overlay's in-context underline (`refreshUnitMark`) so
  /// the stored span matches what the user saw highlighted.
  ///
  /// Returns nil when there's no context, the unit isn't literally present (e.g.
  /// the user typed a lemma the sentence inflects), OR the unit appears MORE THAN
  /// ONCE. The multiple-occurrence case is the important one: from `(unit,
  /// context)` alone we can't tell which occurrence was actually captured, and
  /// downstream treats a non-nil span as authoritative — so a guessed-wrong
  /// occurrence would highlight the wrong text (e.g. unit `art` in `partial art`
  /// would mark the `art` inside `partial`). A nil pair is valid ("no span"); the
  /// reader falls back to its own search rather than a confidently-wrong offset.
  static func span(unit: String, in context: String?) -> (start: Int, end: Int)? {
    let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let context, !context.isEmpty, !u.isEmpty else { return nil }
    let ns = context as NSString
    let first = ns.range(of: u, options: .caseInsensitive)
    guard first.location != NSNotFound else { return nil }
    // Ambiguity guard: bail if there's a second occurrence anywhere after the first. Search from one
    // unit past the first match's START (not its end) so an OVERLAPPING occurrence is still detected
    // (e.g. unit `ana` matches `banana` at offset 1 AND 3 — the second overlaps the first).
    let searchStart = first.location + 1
    if searchStart < ns.length {
      let rest = NSRange(location: searchStart, length: ns.length - searchStart)
      let second = ns.range(of: u, options: .caseInsensitive, range: rest)
      if second.location != NSNotFound { return nil }
    }
    return (first.location, first.location + first.length)
  }
}
