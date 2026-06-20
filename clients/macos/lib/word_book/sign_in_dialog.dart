import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../backend/distribution.dart';

/// A small modal that hosts the shared [SignInPanel] for the Word Book's pre-login "Sign in" — it pops
/// itself the moment sign-in succeeds, so the catalog (which reloads on the auth flip) takes over.
class SignInDialog extends StatefulWidget {
  const SignInDialog({super.key, required this.p, required this.auth});

  final OnboardingPalette p;
  final AuthController auth;

  @override
  State<SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<SignInDialog> {
  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_onAuth);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (widget.auth.isSignedIn && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return Dialog(
      backgroundColor: p.canvas,
      surfaceTintColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Sign in to Capecho', style: p.display(size: 21, color: p.ink)),
              const SizedBox(height: 6),
              Text(
                'Back up your words across your devices and start spaced-repetition review. '
                'Your words on this Mac stay put until you choose to sync them.',
                style: p.body(size: 13.5, height: 1.5, color: p.ink2),
              ),
              const SizedBox(height: 18),
              Center(
                child: SignInPanel(p: p, auth: widget.auth, appleAvailable: isMacAppStoreBuild()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
