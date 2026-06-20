import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capecho_local_store/capecho_local_store.dart' show WordRow, ContextRow;

import 'capture_repository.dart';

/// Adapts the app's [CaptureRepository] to the [LocalWordBook] the Word Book controller reads when
/// signed out. Surfaces ANONYMOUS (`claimed = 0`) rows only — the isolation that keeps account-synced
/// words out of the signed-out catalog.
class RepoWordBook implements LocalWordBook {
  RepoWordBook(this._repo);
  final CaptureRepository _repo;

  @override
  List<WordRow> words() => _repo.anonymousWords();

  @override
  List<ContextRow> contexts(String wordClientRowId) => _repo.contextsFor(wordClientRowId);

  @override
  void softDelete(String wordClientRowId) => _repo.softDelete(wordClientRowId);

  @override
  void restore(String wordClientRowId) => _repo.restore(wordClientRowId);
}
