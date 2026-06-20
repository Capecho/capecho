import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Language picker — a bottom sheet of selectable language rows, used for both the learning
/// (capture-target) and explanation (gloss) language. The [codes] set is passed in; pops the chosen
/// code to the caller.
class LanguageSheet extends StatelessWidget {
  const LanguageSheet({
    super.key,
    required this.p,
    required this.title,
    required this.codes,
    required this.current,
  });
  final OnboardingPalette p;
  final String title;
  final List<String> codes;
  final String? current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(title, style: p.display(size: 18, color: p.ink)),
          ),
          // Scroll the options so the full set stays reachable on a short screen / within the
          // bottom-sheet height cap, instead of overflowing.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final code in codes)
                    InkWell(
                      onTap: () => Navigator.of(context).pop(code),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                langName(code),
                                style: p.chrome(
                                  size: 15,
                                  weight: code == current ? FontWeight.w600 : FontWeight.w400,
                                  color: p.ink,
                                ),
                              ),
                            ),
                            if (code == current) Icon(Icons.check, size: 18, color: p.primary),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
