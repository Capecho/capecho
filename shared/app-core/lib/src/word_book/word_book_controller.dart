import 'dart:async';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_local_store/capecho_local_store.dart' show WordRow, ContextRow;
import 'package:flutter/foundation.dart';

/// Drives the macOS Word Book: load the account's saved words (`/words`), browse them newest-first in a
/// single-column catalog, search by unit, surface "N due today" (`/review/due`
/// count), and open a word's detail as a pushed route (its meaning via `/explain` + its saved contexts
/// via `/contexts`). Each catalog row's context snippet loads lazily as it scrolls in.
///
/// Word delete + restore PERSIST to the backend (`DELETE /words/{id}` /
/// `POST /words/{id}/restore`) optimistically — the local lists update instantly (Undo +
/// Recently-deleted feel immediate) and roll back if the server call fails. Restore PRESERVES the
/// unit's FSRS server-side (distinct from resurrect-on-resave, which resets to a new card). The
/// per-row/detail **FSRS memory meter** reads the per-unit `Word.fsrs` projection `/words` now
/// returns. (Unit-text edit is the one thing that stays UI-local — the unit is immutable by design.)
///
/// Platform-agnostic pure Dart on [CapechoApi] (no Flutter/macOS deps beyond [ChangeNotifier]) so it
/// lifts into a shared package when the mobile client reuses it — the UI stays per-platform.
enum WordBookPhase { loading, loaded, empty, error }

/// How a word's meaning resolved (lazily, when its detail opens).
enum DetailMeaningStatus { idle, loading, ready, unsupported, unavailable }

/// The outcome of the paid "explain in this sentence" call: a stored gloss now renders (ready), the
/// daily quota is spent (quota), the device is offline (offline), or generation failed (failed,
/// retryable).
enum ContextExplainOutcome { ready, quota, offline, failed }

/// One catalog entry — a [Word] plus its lazily-loaded detail (contexts + meaning).
class WordBookEntry {
  WordBookEntry(this.word);

  final Word word;
  String get id => word.id;
  String get unit => word.surfaceUnit;

  bool detailLoaded = false; // meaning + contexts both resolved (the detail view is complete)
  bool _detailLoading = false;
  bool contextsLoaded =
      false; // contexts fetched (by the catalog snippet OR the detail) — dedupes both
  bool _contextLoading = false;
  List<ContextView> contexts = const [];
  bool contextsFailed =
      false; // a fetch error (≠ genuinely context-less — don't show the WB-5 invite)
  WordExplanation? meaning;
  DetailMeaningStatus meaningStatus = DetailMeaningStatus.idle;

  /// When this entry was soft-deleted locally ("Recently deleted"). UI-local until the backend
  /// soft-delete route lands; drives the "deleted N ago" age line.
  DateTime? locallyDeletedAt;

  /// The most-recent saved context — the catalog row's snippet.
  ContextView? get latestContext => contexts.isEmpty ? null : contexts.first;
}

/// The signed-out Word Book's data source: the device-local store (the app wires it from its
/// `CaptureRepository`). Abstracted so this controller stays free of sqlite / platform deps — it lifts
/// into a shared package for the mobile client. It surfaces only ANONYMOUS (`claimed = 0`) rows, which
/// is what keeps a signed-out catalog from ever showing account-synced words.
abstract class LocalWordBook {
  /// Active, anonymous local words, newest-first.
  List<WordRow> words();

  /// The saved context sentences for a local word (by its `client_row_id`), newest-first.
  List<ContextRow> contexts(String wordClientRowId);

  /// Soft-delete a local word (the signed-out catalog's delete; Undo via [restore]).
  void softDelete(String wordClientRowId);

  /// Restore a soft-deleted local word (the signed-out catalog's Undo).
  void restore(String wordClientRowId);
}

/// Adapt a local [WordRow] into the [Word] the catalog renders. Fields the device can't know offline
/// are neutral: [Word.id] is the local `client_row_id` (catalog select / delete / contexts all key off
/// it, and it's never sent to the server signed-out); `fsrs` null (the row shows the phrase tag
/// + the "not yet scheduled" treatment, never the server meter); `explanationState` pending.
Word _wordFromRow(WordRow r) => Word(
  id: r.clientRowId,
  userId: '',
  targetLanguage: r.targetLanguage,
  surfaceUnit: r.surfaceUnit,
  normalizedUnit: r.normalizedUnit,
  targetNormalizationVersion: r.targetNormalizationVersion,
  isPhrase: r.isPhrase,
  explanationState: ExplanationState.pending,
  explanationCacheKey: null,
  fsrsEpoch: 0,
  createdAt: r.createdAt,
  updatedAt: r.updatedAt,
  deletedAt: r.deletedAt,
  fsrs: null,
);

/// Adapt a local [ContextRow] into the [ContextView] the detail renders. [ContextView.id] is the local
/// `client_row_id`; [ContextView.contextText] coalesces the nullable local text to '' (the view's is
/// non-null). [ContextView.meaning] carries the locally-cached in-sentence "Explain here" gloss when one
/// was generated at capture (so the signed-out Word Book shows it without re-generating); null otherwise.
ContextView _contextFromRow(ContextRow r) => ContextView(
  id: r.clientRowId,
  wordId: r.wordClientRowId,
  contextLanguage: r.contextLanguage,
  contextText: r.contextText ?? '',
  spanStart: r.spanStart,
  spanEnd: r.spanEnd,
  meaning: r.glossMeaning,
  // Capture provenance is stored locally too, so a signed-out Word Book / Review shows the source.
  sourceApp: r.sourceApp,
  sourceTitle: r.sourceTitle,
  createdAt: r.createdAt,
);

class WordBookController extends ChangeNotifier {
  WordBookController({required this.api, this.local, this.explanationLanguage = 'en'});

  final CapechoApi api;

  /// The signed-out data source (the device-local store). Null → no local catalog, so the signed-out
  /// path falls back to the server 401 banner (preserves prior behavior, e.g. in tests).
  final LocalWordBook? local;

  final String explanationLanguage;

  WordBookPhase _phase = WordBookPhase.loading;
  WordBookPhase get phase => _phase;

  String? _error;
  String? get error => _error;

  final List<WordBookEntry> _all = []; // active words, newest-first (WB-2)
  int get totalCount => _all.length;

  /// True when a bearer session is held. Pre-login, units have no server FSRS schedule, so the catalog
  /// shows the calm "not yet scheduled — sign in to review" treatment with no meter.
  bool get signedIn => api.hasSession;
  bool get preLogin => !api.hasSession;

  /// Soft-deleted units, newest-deletion-first ("Recently deleted"). UI-local until the backend
  /// soft-delete/restore routes land. [restoreEntry] brings one back to the active catalog.
  final List<WordBookEntry> _deleted = [];
  List<WordBookEntry> get recentlyDeleted => List.unmodifiable(_deleted);

  /// The sign-in state at the last [load], to detect a source switch (local ↔ server). Null until the
  /// first load.
  bool? _lastSignedIn;

  /// "N due today" for the masthead. Server-authoritative FSRS count from `/review/due`; null until it
  /// resolves (or if it fails — the masthead just omits the line then).
  int? _dueToday;
  int? get dueToday => _dueToday;

  String _query = '';
  String get query => _query;

  /// The catalog filtered by [query] — matches the unit (WB-3 also wants meaning; meaning isn't in the
  /// catalog yet, so v1 searches the unit + its normalized form).
  List<WordBookEntry> get visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return List.unmodifiable(_all);
    return _all
        .where(
          (e) =>
              e.word.surfaceUnit.toLowerCase().contains(q) ||
              e.word.normalizedUnit.toLowerCase().contains(q),
        )
        .toList();
  }

  String? _selectedId;
  String? get selectedId => _selectedId;
  WordBookEntry? get selected => _selectedId == null ? null : _entry(_selectedId!);

  bool _disposed = false;

  Future<void> load() async {
    _phase = WordBookPhase.loading;
    _error = null;
    // A signed-out ↔ signed-in source switch invalidates the session-scratch Recently-deleted list:
    // its ids are local client_row_ids on one side and server word ids on the other, so a stale entry
    // would route Restore to the wrong backend. Clear on a FLIP only — a same-session reload (e.g.
    // after a sync) keeps the Undo list intact.
    final signedIn = api.hasSession;
    if (_lastSignedIn != null && _lastSignedIn != signedIn) _deleted.clear();
    _lastSignedIn = signedIn;
    _notify();
    // Signed out: read the device-local ANONYMOUS catalog (no account, no server round-trip). The
    // signed-IN path stays server-authoritative below.
    if (!api.hasSession && local != null) {
      _loadLocal();
      return;
    }
    try {
      final words = await api.listWords();
      final active = words.where((w) => w.deletedAt == null).toList()
        ..sort((a, b) {
          final c = b.createdAt.compareTo(a.createdAt); // newest-first (WB-2)
          return c != 0
              ? c
              : b.id.compareTo(a.id); // stable tiebreak (mirrors the server's id order)
        });
      _all
        ..clear()
        ..addAll(active.map(WordBookEntry.new));
      if (_all.isEmpty) {
        _phase = WordBookPhase.empty;
        _selectedId = null;
      } else {
        _phase = WordBookPhase.loaded;
        // Single-column catalog: the detail is a pushed route, so nothing is auto-selected. Each row's
        // context snippet loads lazily as it scrolls in.
      }
      unawaited(
        _loadDueCount(),
      ); // best-effort "N due today" for the masthead (never blocks the list)
      _notify();
    } catch (e) {
      _phase = WordBookPhase.error;
      _error = (e is ApiException && e.isUnauthorized)
          ? 'Sign in to see your Word Book.'
          : 'Couldn’t load your Word Book — check your connection.';
      _notify();
    }
  }

  /// Signed-out load: the device-local anonymous catalog. The store already returns active,
  /// anonymous rows newest-first, so no extra sort is needed. There's no server FSRS offline, so
  /// `dueToday` is left null (the masthead omits it) and rows render the "not yet scheduled" treatment.
  void _loadLocal() {
    final rows = local!.words();
    _all
      ..clear()
      ..addAll(rows.map((r) => WordBookEntry(_wordFromRow(r))));
    _dueToday = null;
    if (_all.isEmpty) {
      _phase = WordBookPhase.empty;
      _selectedId = null;
    } else {
      _phase = WordBookPhase.loaded;
    }
    _notify();
  }

  void search(String q) {
    _query = q;
    _notify();
  }

  void select(String id) {
    if (_selectedId == id) return;
    _selectedId = id;
    final e = _entry(id);
    _notify();
    if (e != null && !e.detailLoaded) unawaited(_loadDetail(e));
  }

  /// Re-fetch the detail (meaning + contexts) for [id] after a load failure — wired to the detail
  /// pane's Retry affordances so a transient error isn't a session-long dead end.
  void retryDetail(String id) {
    final e = _entry(id);
    if (e == null || e._detailLoading) return;
    e.detailLoaded = false;
    e.contextsLoaded = false; // re-fetch contexts too (a prior fetch may have failed)
    e.contextsFailed = false;
    e.meaningStatus = DetailMeaningStatus.loading;
    _notify();
    unawaited(_loadDetail(e));
  }

  Future<void> _loadDetail(WordBookEntry e) async {
    if (e.detailLoaded || e._detailLoading) return;
    e._detailLoading = true;
    e.meaningStatus = DetailMeaningStatus.loading;
    _notify();

    // Fetch contexts unless they're already loaded OK, or a catalog snippet fetch is mid-flight (then
    // that fetch's notify fills them in — avoids a duplicate `/contexts`). A prior FAILED snippet
    // fetch DOES re-fetch here, so opening the detail isn't poisoned by a transient blip.
    if ((!e.contextsLoaded || e.contextsFailed) && !e._contextLoading) await _fetchContexts(e);
    try {
      final res = await api.explain(
        unit: e.word.surfaceUnit,
        target: e.word.targetLanguage,
        explanationLang: explanationLanguage,
        wordId: e.id,
      );
      if (res.status == ExplainStatus.languageUnsupported) {
        e.meaningStatus = DetailMeaningStatus.unsupported;
      } else if (res.explanation != null && res.explanation!.primarySense.trim().isNotEmpty) {
        // The primary sense is the must-pass core (server-side) — a blob with no sense isn't "ready".
        e.meaning = res.explanation;
        e.meaningStatus = DetailMeaningStatus.ready;
      } else {
        e.meaningStatus = DetailMeaningStatus.unavailable;
      }
    } catch (_) {
      e.meaningStatus = DetailMeaningStatus.unavailable;
    }
    e._detailLoading = false;
    e.detailLoaded = true;
    _notify();
  }

  /// Lazily fetch a catalog row's most-recent context for its snippet — a cheap `/contexts` call, NOT
  /// the AI `explain`. Called as rows scroll in; deduped so each word is
  /// fetched once whether it's the catalog snippet or the opened detail that triggers it.
  Future<void> ensureCatalogContext(WordBookEntry e) async {
    if (e.contextsLoaded || e._contextLoading || e._detailLoading) return;
    e._contextLoading = true;
    await _fetchContexts(e);
    e._contextLoading = false;
    _notify();
  }

  Future<void> _fetchContexts(WordBookEntry e) async {
    try {
      // Signed out: read contexts from the local store (server `/contexts` is account-scoped → 401).
      e.contexts = (!api.hasSession && local != null)
          ? local!.contexts(e.id).map(_contextFromRow).toList()
          : await api.contexts(e.id);
      e.contextsFailed = false;
    } catch (_) {
      e.contexts = const [];
      e.contextsFailed = true; // a fetch error — not a genuinely context-less word
    }
    e.contextsLoaded = true;
  }

  ContextView? _context(WordBookEntry e, String contextId) {
    for (final c in e.contexts) {
      if (c.id == contextId) return c;
    }
    return null;
  }

  /// Replace one context in [e] (by id) with [updated], in place, and notify.
  void _replaceContext(WordBookEntry e, String contextId, ContextView updated) {
    e.contexts = [for (final c in e.contexts) c.id == contextId ? updated : c];
    _notify();
  }

  /// Paid "explain in this sentence" (`POST /explain/context`, metered §16). On success stores the
  /// returned gloss on the context (which then renders) and returns [ContextExplainOutcome.ready];
  /// otherwise maps quota/offline/failed for the detail's states.
  Future<ContextExplainOutcome> explainContext(WordBookEntry e, String contextId) async {
    try {
      final res = await api.explainContext(contextId, explanationLang: explanationLanguage);
      final c = _context(e, contextId);
      if (c != null) {
        _replaceContext(e, contextId, c.copyWith(meaning: res.meaning));
      }
      return ContextExplainOutcome.ready;
    } on ApiException catch (err) {
      // Only `quota_exhausted` (429) gets the distinct quota surface. The rest — `budget_exhausted`
      // (503, transient), `not_found` (404), `conflict` (409), `generation_failed` (502) — collapse to
      // the failed state ("our side, try again"). The 503/409 cases are rare; "try again" is the
      // least-wrong of the designed states.
      return err.error == 'quota_exhausted'
          ? ContextExplainOutcome.quota
          : ContextExplainOutcome.failed;
    } catch (_) {
      return ContextExplainOutcome.offline; // a true transport failure (no network)
    }
  }

  /// Edit a saved context's sentence (`PATCH /contexts/{id}`). The server clears that context's stored
  /// gloss (it was for the old sentence), so we clear it locally too. Returns null on success, else a
  /// short error message for the inline editor.
  Future<String?> editContext(WordBookEntry e, String contextId, String text) async {
    try {
      await api.editContext(contextId, text);
      final c = _context(e, contextId);
      if (c != null) _replaceContext(e, contextId, c.copyWith(contextText: text, clearGloss: true));
      return null;
    } on ApiException catch (err) {
      if (err.error == 'empty_context') return 'A sentence can’t be empty.';
      if (err.error == 'context_too_large') return 'That sentence is too long.';
      return 'Couldn’t save — try again.';
    } catch (_) {
      return 'Couldn’t save — check your connection.';
    }
  }

  /// Remove a saved context (`DELETE /contexts/{id}`). Returns null on success, else an error message.
  Future<String?> removeContext(WordBookEntry e, String contextId) async {
    try {
      await api.deleteContext(contextId);
      e.contexts = [
        for (final c in e.contexts)
          if (c.id != contextId) c,
      ];
      _notify();
      return null;
    } catch (_) {
      return 'Couldn’t remove — try again.';
    }
  }

  Future<void> _loadDueCount() async {
    try {
      _dueToday = (await api.dueReviews()).dueCount;
      _notify();
    } catch (_) {
      // best-effort: the masthead simply omits "N due today" if the count can't be fetched.
    }
  }

  /// Soft-delete a unit: optimistically drop it from the active catalog into [recentlyDeleted], then
  /// persist `DELETE /words/{id}`. On a server failure it rolls back into the
  /// catalog so the list reflects the truth. The detail's "Delete word" + the catalog Undo route here.
  void deleteEntry(String id) {
    final i = _all.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final e = _all.removeAt(i);
    e.locallyDeletedAt = DateTime.now();
    _deleted.insert(0, e); // newest deletion first
    if (_all.isEmpty && _query.trim().isEmpty) _phase = WordBookPhase.empty;
    if (_selectedId == id) _selectedId = null;
    _notify();
    unawaited(_persistDelete(id, e));
  }

  Future<void> _persistDelete(String id, WordBookEntry e) async {
    try {
      if (!api.hasSession && local != null) {
        local!.softDelete(id);
      } else {
        await api.deleteWord(id);
      }
    } catch (_) {
      // Roll the optimistic delete back so the catalog matches the server (best-effort; if the user
      // already hit Undo, `e` is no longer in `_deleted` and we leave it).
      if (_disposed || !_deleted.remove(e)) return;
      e.locallyDeletedAt = null;
      _all.add(e);
      _resortActive();
      if (_phase == WordBookPhase.empty) _phase = WordBookPhase.loaded;
      _notify();
    }
  }

  /// Restore a soft-deleted unit: optimistically move it back into the active catalog (newest-first),
  /// then persist `POST /words/{id}/restore` — which PRESERVES its FSRS
  /// (distinct from resurrect-on-resave, which resets to a new card). Rolls back on a server failure.
  void restoreEntry(String id) {
    final i = _deleted.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final e = _deleted.removeAt(i);
    e.locallyDeletedAt = null;
    _all.add(e);
    _resortActive();
    if (_phase == WordBookPhase.empty) _phase = WordBookPhase.loaded;
    _notify();
    unawaited(_persistRestore(id, e));
  }

  Future<void> _persistRestore(String id, WordBookEntry e) async {
    try {
      if (!api.hasSession && local != null) {
        local!.restore(id);
      } else {
        await api.restoreWord(id);
      }
    } catch (_) {
      if (_disposed || !_all.remove(e)) return;
      e.locallyDeletedAt = DateTime.now();
      _deleted.insert(0, e);
      if (_all.isEmpty && _query.trim().isEmpty) _phase = WordBookPhase.empty;
      _notify();
    }
  }

  /// Re-sort the active catalog newest-first (WB-2), with a stable id tiebreak mirroring the server.
  void _resortActive() {
    _all.sort((a, b) {
      final c = b.word.createdAt.compareTo(a.word.createdAt);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
  }

  /// Export the Word Book as CSV text (the screen saves it to a `.csv` file via the native save panel).
  /// [attribution] adds the "captured with Capecho" footer column (off by default — the r/Anki community
  /// punishes spam). Null on failure.
  Future<String?> exportCsv({bool attribution = false}) async {
    try {
      return await api.exportCsv(attribution: attribution);
    } catch (_) {
      return null;
    }
  }

  /// Export the Word Book as structured rows — the source for the one-click Anki `.apkg` deck the macOS
  /// client builds locally (SQLite `collection.anki2` + zip). One [ExportRow] per active unit. Null on
  /// failure (same calm "couldn't export, try again" surface as [exportCsv]).
  Future<List<ExportRow>?> exportRows() async {
    try {
      return await api.exportRows();
    } catch (_) {
      return null;
    }
  }

  void retry() => load();

  WordBookEntry? _entry(String id) {
    for (final e in _all) {
      if (e.id == id) return e;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
