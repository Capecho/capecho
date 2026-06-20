import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Delete-account confirm dialog — a deliberate confirm gate, then the hard-delete via
/// `DELETE /account`. The bearer session IS the auth (per the backend), so the gate is friction, not a
/// separate re-verify; re-signing in within the 30-day window cancels the deletion.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key, required this.p, required this.auth});
  final OnboardingPalette p;
  final AuthController auth;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  bool _reauthed = false;
  bool _deleting = false;
  String? _error;

  Future<void> _confirmDelete() async {
    if (_deleting) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      // Marks the account for deletion + revokes the session (the bearer token is the auth). Settings,
      // watching `auth`, flips to its signed-out state behind this dialog as the token drops.
      await widget.auth.deleteAccount();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _deleting = false;
          _error = 'Couldn’t delete your account — check your connection and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return Dialog(
      backgroundColor: p.card,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: p.line),
        borderRadius: BorderRadius.circular(11),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        // Scrollable so the tall confirm content never overflows a short window.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: p.error.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.warning_amber_rounded, size: 24, color: p.error),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Delete your account & data?',
                  style: p.display(size: 20, color: p.ink),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'This deletes the data tied to your account. It can’t be undone after you confirm.',
                style: p
                    .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                    .copyWith(height: 1.6),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  color: p.canvas,
                  border: Border.all(color: p.line),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _bullet(p, 'Your saved words and their contexts'),
                    _bullet(p, 'Your review history & schedules'),
                    _bullet(p, 'Your context-sentence text (hard-deleted, not archived)'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Your data is fully purged within 30 days. Your shared, anonymous word explanations stay in '
                'the public cache.',
                style: p
                    .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                    .copyWith(height: 1.6),
              ),
              const SizedBox(height: 16),
              // A deliberate confirm gate: the user explicitly confirms before the destructive button
              // arms. The bearer session is the auth (the backend treats DELETE /account as
              // session-authorized), so this is friction, not a separate cryptographic re-verify.
              Text(
                'Confirm to permanently delete',
                style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink2),
              ),
              const SizedBox(height: 6),
              if (_reauthed)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: p.canvas,
                    border: Border.all(color: p.error),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('Confirmed ✓', style: p.mono(size: 13, color: p.ink)),
                )
              else
                ObQuietButton(
                  p: p,
                  label: 'I understand — confirm',
                  onPressed: () => setState(() => _reauthed = true),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: p
                      .chrome(size: 12.5, weight: FontWeight.w400, color: p.error)
                      .copyWith(height: 1.4),
                ),
              ],
              const SizedBox(height: 16),
              // The destructive primary — oxblood, armed only after the confirm gate; calls DELETE /account.
              _DangerSolidButton(
                p: p,
                label: _deleting ? 'Deleting…' : 'Delete account & data',
                onPressed: (_reauthed && !_deleting) ? _confirmDelete : null,
              ),
              const SizedBox(height: 8),
              Center(
                child: ObQuietButton(
                  p: p,
                  label: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bullet(OnboardingPalette p, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('—  ', style: p.chrome(size: 13, color: p.ink3)),
        Expanded(
          child: Text(
            text,
            style: p
                .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                .copyWith(height: 1.45),
          ),
        ),
      ],
    ),
  );
}

/// The solid oxblood destructive button, dimmed when disabled.
class _DangerSolidButton extends StatelessWidget {
  const _DangerSolidButton({required this.p, required this.label, required this.onPressed});
  final OnboardingPalette p;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: p.error,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            height: 40,
            alignment: Alignment.center,
            child: Text(
              label,
              style: p.chrome(size: 14, weight: FontWeight.w600, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
