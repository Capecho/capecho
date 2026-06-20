//
//  CaptureJournal.swift
//  capture_native
//
//  The durable, append-only capture journal (ENG-1). This is the persistence
//  BOUNDARY: a save appends one JSON-lines record and fsyncs it to disk BEFORE
//  the caller (the overlay) shows the "saved" ink-dot. The Flutter side later
//  DRAINS the journal into the queryable local store — that drain is an async,
//  idempotent projection, never the durable write — so a stalled/dead Flutter
//  isolate cannot lose a saved capture (the journal re-drains on next launch).
//
//  Flutter-agnostic on purpose (no FlutterMacOS import): the plugin calls it.
//

import Foundation

private enum JournalError: Error {
  case fsyncFailed
}

/// Append-only, fsync'd capture journal stored under Application Support.
final class CaptureJournal {
  /// One line per record (JSON object + "\n"). Records carry a per-install
  /// monotonic `seq` (the drain cursor key) and a `clientRowId` (the per-save
  /// UUID == the local store's context row id, the idempotency unit).
  private let journalURL: URL
  private let installIDURL: URL
  private let queue = DispatchQueue(label: "app.capecho.capture-journal")

  private let installIDValue: String
  private var maxSeq: Int

  init(directory: URL? = nil) {
    let baseDir = directory ?? CaptureJournal.defaultDirectory()
    try? FileManager.default.createDirectory(
      at: baseDir, withIntermediateDirectories: true)
    self.journalURL = baseDir.appendingPathComponent("capture-journal.jsonl")
    self.installIDURL = baseDir.appendingPathComponent("install-id")
    self.installIDValue = CaptureJournal.loadOrCreateInstallID(at: installIDURL)
    self.maxSeq = CaptureJournal.highestSeq(in: journalURL)
  }

  var installID: String { installIDValue }

  /// Appends one capture record and fsyncs. Returns `["clientRowId": String,
  /// "seq": Int]` on success, or `["error": String]` on failure. Synchronous:
  /// the durable write completes before this returns (so the ink-dot is honest).
  func append(
    surfaceUnit: String,
    targetLanguage: String,
    contextText: String?,
    contextLanguage: String?,
    spanStart: Int?,
    spanEnd: Int?,
    source: String,
    sourceApp: String?,
    sourceTitle: String?,
    detectedLanguage: String?,
    detectedLanguageConfidence: Double?,
    capturedAt: Int
  ) -> [String: Any] {
    return queue.sync {
      let seq = maxSeq + 1
      let clientRowId = UUID().uuidString
      var record: [String: Any] = [
        "seq": seq,
        "clientRowId": clientRowId,
        "installId": installIDValue,
        "surfaceUnit": surfaceUnit,
        "targetLanguage": targetLanguage,
        "source": source,
        "capturedAt": capturedAt,
      ]
      record["contextText"] = contextText ?? NSNull()
      record["contextLanguage"] = contextLanguage ?? NSNull()
      record["spanStart"] = spanStart ?? NSNull()
      record["spanEnd"] = spanEnd ?? NSNull()
      // Capture-source provenance ("where I met this word") + the capture-time detected language —
      // optional metadata the Dart drain reads (JournalEntry.fromMap); NSNull when absent so the
      // sorted-keys JSON stays a faithful, replayable round-trip.
      record["sourceApp"] = sourceApp ?? NSNull()
      record["sourceTitle"] = sourceTitle ?? NSNull()
      record["detectedLanguage"] = detectedLanguage ?? NSNull()
      record["detectedLanguageConfidence"] = detectedLanguageConfidence ?? NSNull()

      guard
        let json = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      else {
        return ["error": "encodeFailed"]
      }
      var line = json
      line.append(0x0A) // '\n'

      do {
        try appendDurably(line)
      } catch {
        return ["error": "writeFailed"]
      }

      maxSeq = seq
      return ["clientRowId": clientRowId, "seq": seq]
    }
  }

  /// Returns every record with `seq > afterSeq`, in ascending seq order, as the
  /// plain dictionaries the Dart `JournalEntry.fromMap` expects.
  func entries(afterSeq: Int) -> [[String: Any]] {
    return queue.sync {
      guard let data = try? Data(contentsOf: journalURL) else { return [] }
      var out: [[String: Any]] = []
      for lineData in data.split(separator: 0x0A) where !lineData.isEmpty {
        guard
          let obj = try? JSONSerialization.jsonObject(with: Data(lineData)),
          let record = obj as? [String: Any],
          let seq = record["seq"] as? Int,
          seq > afterSeq
        else { continue }
        out.append(record)
      }
      out.sort { ($0["seq"] as? Int ?? 0) < ($1["seq"] as? Int ?? 0) }
      return out
    }
  }

  // MARK: - Durable append

  /// Appends `data` to the journal file and forces it to stable storage with
  /// `F_FULLFSYNC` (macOS: a plain `fsync` does not flush the drive's own cache;
  /// F_FULLFSYNC does — the correct durability barrier for "saved").
  private func appendDurably(_ data: Data) throws {
    if !FileManager.default.fileExists(atPath: journalURL.path) {
      FileManager.default.createFile(atPath: journalURL.path, contents: nil)
    }
    // O_RDWR (not O_WRONLY): the torn-line guard below reads the last byte;
    // `read(upToCount:)` on a write-only handle fails with EBADF.
    let handle = try FileHandle(forUpdating: journalURL)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    // Guard against a torn (newline-less) trailing line left by a prior crash:
    // if the file doesn't already end in '\n', insert one FIRST, so the torn
    // fragment becomes its own (unparseable, skipped) line and our new record
    // never concatenates onto garbage and get silently dropped on recovery
    // (review P1).
    if end > 0 {
      try handle.seek(toOffset: end - 1)
      let last = try handle.read(upToCount: 1)
      try handle.seekToEnd()
      if last != Data([0x0A]) {
        try handle.write(contentsOf: Data([0x0A]))
      }
    }
    try handle.write(contentsOf: data)
    // Force to stable storage. F_FULLFSYNC is the macOS-correct full barrier;
    // fall back to fsync. If BOTH fail, throw — the caller must NOT signal
    // "saved" on a non-durable write (review N1).
    if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
      if fsync(handle.fileDescriptor) == -1 {
        throw JournalError.fsyncFailed
      }
    }
  }

  // MARK: - Setup helpers

  private static func defaultDirectory() -> URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return appSupport.appendingPathComponent("Capecho", isDirectory: true)
  }

  private static func loadOrCreateInstallID(at url: URL) -> String {
    if let existing = try? String(contentsOf: url, encoding: .utf8) {
      let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    let fresh = UUID().uuidString
    // Persist durably (fsync) so a crash right after the first (fsync'd) journal
    // append can't orphan the journal's installId against a freshly-regenerated
    // one on the next launch (review M3).
    if let data = fresh.data(using: .utf8) {
      FileManager.default.createFile(atPath: url.path, contents: data)
      if let handle = try? FileHandle(forUpdating: url) {
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        try? handle.close()
      }
    }
    return fresh
  }

  /// The highest `seq` already in the journal (0 when empty/absent), so a
  /// relaunch continues the monotonic sequence.
  private static func highestSeq(in url: URL) -> Int {
    guard let data = try? Data(contentsOf: url) else { return 0 }
    var maxSeq = 0
    for lineData in data.split(separator: 0x0A) where !lineData.isEmpty {
      if let obj = try? JSONSerialization.jsonObject(with: Data(lineData)),
        let record = obj as? [String: Any],
        let seq = record["seq"] as? Int {
        maxSeq = max(maxSeq, seq)
      }
    }
    return maxSeq
  }
}
