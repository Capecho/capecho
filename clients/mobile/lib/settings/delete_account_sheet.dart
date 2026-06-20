import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Delete-account confirm sheet — a deliberate confirm gate, then the hard-delete via DELETE /account.
/// The bearer session is the auth (per the backend), so the gate is friction, not a separate
/// cryptographic re-verify (a fresh provider sheet the backend doesn't require). Re-signing in within
/// the retention window cancels the deletion.
class DeleteAccountSheet extends StatefulWidget {
  const DeleteAccountSheet({super.key, required this.p, required this.auth});
  final OnboardingPalette p;
  final AuthController auth;

  @override
  State<DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<DeleteAccountSheet> {
  bool _confirmed = false;
  bool _deleting = false;
  String? _error;

  Future<void> _confirmDelete() async {
    if (_deleting) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      // Marks the account for deletion + revokes the session (the bearer token is the auth). The
      // shell, watching `auth`, returns to sign-in as the token drops.
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
    final email = widget.auth.account?.email;
    // Bottom-sheet treatment: rounded top, scrollable so the tall content never overflows a short
    // screen, padded above the keyboard inset if one ever appears.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: p.error.withValues(alpha: p.dark ? 0.14 : 0.12),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.warning_amber_rounded, size: 22, color: p.error),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    'Delete your account & data?',
                    textAlign: TextAlign.center,
                    style: p.display(size: 19, color: p.ink),
                  ),
                ),
                const SizedBox(height: 10),
                Text.rich(
                  TextSpan(
                    style: p
                        .chrome(size: 12.5, weight: FontWeight.w400, color: p.ink2)
                        .copyWith(height: 1.55),
                    children: [
                      const TextSpan(text: 'This deletes the data tied to '),
                      TextSpan(
                        text: (email != null && email.isNotEmpty) ? email : 'your account',
                        style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                      ),
                      const TextSpan(text: '. It can’t be undone after you confirm.'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  'Your data is fully purged within 30 days. Your shared, anonymous word explanations '
                  'stay in the public cache.',
                  style: p
                      .chrome(size: 12.5, weight: FontWeight.w400, color: p.ink2)
                      .copyWith(height: 1.55),
                ),
                const SizedBox(height: 14),
                // A deliberate confirm gate: the destructive button arms only after an explicit
                // confirm. The bearer session is the auth (the backend treats DELETE /account as
                // session-authorized), so this is friction, not a separate provider re-verify.
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Confirm to permanently delete',
                    style: p.chrome(size: 12.5, weight: FontWeight.w400, color: p.ink2),
                  ),
                ),
                const SizedBox(height: 7),
                if (_confirmed)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                    decoration: BoxDecoration(
                      border: Border.all(color: p.error),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Confirmed ✓',
                      style: p.chrome(size: 13, weight: FontWeight.w600, color: p.error),
                    ),
                  )
                else
                  _ghostBlockButton(
                    p,
                    'I understand — confirm',
                    onPressed: () => setState(() => _confirmed = true),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: p
                        .chrome(size: 12, weight: FontWeight.w400, color: p.error)
                        .copyWith(height: 1.4),
                  ),
                ],
                const SizedBox(height: 14),
                _dangerBlockButton(
                  p,
                  _deleting ? 'Deleting…' : 'Delete account & data',
                  onPressed: (_confirmed && !_deleting) ? _confirmDelete : null,
                ),
                const SizedBox(height: 8),
                _ghostBlockButton(
                  p,
                  'Cancel',
                  onPressed: _deleting ? null : () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bullet(OnboardingPalette p, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('—  ', style: p.chrome(size: 12, color: p.ink3)),
        Expanded(
          child: Text(
            text,
            style: p
                .chrome(size: 12, weight: FontWeight.w400, color: p.ink2)
                .copyWith(height: 1.45),
          ),
        ),
      ],
    ),
  );

  /// A full-width solid oxblood destructive button (dimmed when disabled).
  Widget _dangerBlockButton(OnboardingPalette p, String label, {required VoidCallback? onPressed}) {
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
            constraints: const BoxConstraints(minHeight: 46),
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

  /// A full-width outlined neutral button.
  Widget _ghostBlockButton(OnboardingPalette p, String label, {required VoidCallback? onPressed}) {
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: p.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: p.chrome(size: 14, weight: FontWeight.w500, color: p.ink),
            ),
          ),
        ),
      ),
    );
  }
}
