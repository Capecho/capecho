import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Recently deleted — soft-deleted units with Restore, pushed as a full route on top of the catalog.
/// Backed by the controller's UI-local tombstone list; restoring re-runs `POST /words/{id}/restore`
/// (which preserves the unit's FSRS schedule, unlike re-capturing).

/// A calm relative age for the Recently-deleted list ("deleted N ago"). No purge countdown — show age,
/// not a deadline.
String _deletedAge(DateTime? when) {
  if (when == null) return 'just deleted';
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

class RecentlyDeletedPage extends StatefulWidget {
  const RecentlyDeletedPage({super.key, required this.controller});
  final WordBookController controller;

  @override
  State<RecentlyDeletedPage> createState() => _RecentlyDeletedPageState();
}

class _RecentlyDeletedPageState extends State<RecentlyDeletedPage> {
  WordBookController get _c => widget.controller;

  void _restore(String id) {
    _c.restoreEntry(id);
    // `POST /words/:id/restore` un-deletes the tombstone and PRESERVES its FSRS schedule.
    if (_c.recentlyDeleted.isEmpty) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return Scaffold(
      backgroundColor: p.canvas,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
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
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                  child: Text(
                    'Deleted words and phrases stay here so you can bring them back. Restoring one keeps '
                    'its sentences and its review schedule.',
                    style: p.chrome(size: 12, color: p.ink3, height: 1.5),
                  ),
                ),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Text('Nothing here.', style: p.chrome(size: 13, color: p.ink3)),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                          itemCount: items.length,
                          itemBuilder: (_, i) => _rdRow(p, items[i]),
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
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: Opacity(
        opacity: 0.9, // gently dimmed
        child: Container(
          decoration: BoxDecoration(
            color: p.card,
            border: Border.all(color: p.line),
            borderRadius: BorderRadius.circular(12),
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
                      'Keeps $keeps · ${_deletedAge(e.locallyDeletedAt)}',
                      style: p.chrome(size: 11, color: p.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ObQuietButton(p: p, label: 'Restore', onPressed: () => _restore(e.id)),
            ],
          ),
        ),
      ),
    );
  }
}
