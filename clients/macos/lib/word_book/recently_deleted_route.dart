import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The **Recently deleted** view — soft-deleted units with Restore, pushed on top of the catalog.
/// Backed by the controller's UI-local tombstone list; restoring re-runs `POST /words/{id}/restore`
/// (which preserves the unit's FSRS, unlike re-capturing).
///
/// A calm relative age for the Recently-deleted list ("deleted N ago"). No purge countdown (Q4: show
/// age, not a deadline).
String _deletedAge(DateTime? when) {
  if (when == null) return '';
  final secs = DateTime.now().difference(when).inSeconds;
  if (secs < 60) return 'deleted just now';
  final mins = secs ~/ 60;
  if (mins < 60) return 'deleted $mins min ago';
  final hours = mins ~/ 60;
  if (hours < 24) return 'deleted $hours ${hours == 1 ? 'hour' : 'hours'} ago';
  final days = hours ~/ 24;
  if (days == 1) return 'deleted yesterday';
  return 'deleted $days days ago';
}

class RecentlyDeletedRoute extends StatefulWidget {
  const RecentlyDeletedRoute({super.key, required this.controller});
  final WordBookController controller;

  @override
  State<RecentlyDeletedRoute> createState() => _RecentlyDeletedRouteState();
}

class _RecentlyDeletedRouteState extends State<RecentlyDeletedRoute> {
  final FocusNode _focus = FocusNode(debugLabel: 'recently-deleted');
  WordBookController get _c => widget.controller;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Esc, or ⌘W (standard macOS close) → pop this page (bug #3).
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            (event.logicalKey == LogicalKeyboardKey.keyW &&
                HardwareKeyboard.instance.isMetaPressed))) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _restore(String id) {
    _c.restoreEntry(id);
    // `POST /words/:id/restore` un-deletes the tombstone and PRESERVES its FSRS schedule (restoreWord).
    // Resetting to a new card is the RE-CAPTURE path instead — re-saving the text onto a tombstone
    // bumps fsrs_epoch (ENG-4) — not this restore.
    if (_c.recentlyDeleted.isEmpty) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: p.canvas,
        body: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final items = _c.recentlyDeleted;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SurfaceHeader(
                  p: p,
                  title: 'Recently deleted',
                  onBack: () => Navigator.of(context).maybePop(),
                  backLabel: 'Word Book',
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
                  child: Text(
                    'Deleted words and phrases stay here so you can bring them back. Restoring one keeps '
                    'its sentences and starts its review fresh.',
                    style: p.chrome(size: 12, color: p.ink3, height: 1.5),
                  ),
                ),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Text('Nothing here.', style: p.chrome(size: 13, color: p.ink3)),
                        )
                      : Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 900),
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                              itemCount: items.length,
                              itemBuilder: (_, i) => _rdRow(p, items[i]),
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _rdRow(OnboardingPalette p, WordBookEntry e) {
    final n = e.contextsLoaded ? e.contexts.length : null;
    final keeps = n == null ? 'its sentences' : (n == 1 ? 'its 1 sentence' : 'its $n sentences');
    final ctx = e.latestContext;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Opacity(
        opacity: 0.9, // gently dimmed
        child: Container(
          decoration: BoxDecoration(
            color: p.card,
            border: Border.all(color: p.line),
            borderRadius: BorderRadius.circular(11),
            boxShadow: kSoftEdgeShadow,
          ),
          padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(e.unit, style: p.display(size: 18, color: p.ink2)),
                    if (ctx != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        '“${ctx.contextText}”',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: p.body(size: 13, color: p.ink3, fontStyle: FontStyle.italic),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      'Restoring keeps $keeps · review starts fresh',
                      style: p.chrome(size: 11, color: p.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Text(_deletedAge(e.locallyDeletedAt), style: p.mono(size: 11, color: p.ink3)),
              const SizedBox(width: 12),
              ObQuietButton(p: p, label: 'Restore', onPressed: () => _restore(e.id)),
            ],
          ),
        ),
      ),
    );
  }
}
