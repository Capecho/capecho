//
//  UnitNormalization.swift
//  capture_native
//
//  Mirrors the client dedup-key normalization's "does this unit survive normalization?" rule so the
//  native Save gate can reject a unit that would normalize AWAY — pure logic, separated for testability.
//  Foundation-only; no AppKit, no I/O.
//

import Foundation

/// The device dedup key (clients/macos/lib/capture_repository.dart `localDedupKey`, mirrored from the
/// server's `backend/src/dedup-key.ts`) lowercases, collapses whitespace, trims, then STRIPS leading +
/// trailing runs of non-`[\p{L}\p{M}\p{N}]` (letters / marks / numbers). A unit made of ONLY whitespace
/// and/or punctuation / symbols therefore normalizes to the EMPTY string — and an empty key creates no
/// word on drain. But the native overlay's Save only rejected a *whitespace*-empty unit, so a unit like
/// `###` or `•••` showed a native "Saved" yet silently created nothing (capture-flow P0). This helper
/// lets both Save gates (the overlay's `handleSave` and the durable `appendValidated`) reject such a
/// unit up front, mirroring the dedup key exactly.
enum UnitNormalization {
  /// True when [unit] keeps at least one letter (`\p{L}`), mark (`\p{M}`), or number (`\p{N}`) — i.e.
  /// its dedup key is NON-empty. Equivalent to `localDedupKey(unit) != ""`: the key strips only the
  /// non-L/M/N edge runs, so any unit containing one L/M/N anywhere survives, and one containing none
  /// normalizes away entirely. The same `[\p{L}\p{M}\p{N}]` character class as the Dart/TS key.
  static func hasWordContent(_ unit: String) -> Bool {
    unit.range(of: "[\\p{L}\\p{M}\\p{N}]", options: .regularExpression) != nil
  }
}
