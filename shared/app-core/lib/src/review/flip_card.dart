import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A horizontal 3D flip between [front] and [back], driven by [showBack]. A fresh [cardId] jumps
/// straight to the front with no flip across the swap (so advancing the review queue never animates
/// a turn between two different cards). The back face is pre-rotated a half-turn so it lands
/// un-mirrored at the end of the turn. Flipping on tap/key is the caller's job — this only animates.
class FlipCard extends StatefulWidget {
  const FlipCard({
    super.key,
    required this.showBack,
    required this.cardId,
    required this.front,
    required this.back,
  });

  final bool showBack;
  final Object cardId;
  final Widget front;
  final Widget back;

  @override
  State<FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<FlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    value: widget.showBack ? 1 : 0,
  );

  @override
  void didUpdateWidget(FlipCard old) {
    super.didUpdateWidget(old);
    if (widget.cardId != old.cardId) {
      // A new card always opens on its front — jump there, no flip across the swap.
      _ctrl.value = widget.showBack ? 1 : 0;
    } else if (widget.showBack != old.showBack) {
      widget.showBack ? _ctrl.forward() : _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final angle = Curves.easeInOut.transform(_ctrl.value) * math.pi;
        final showingBack = angle > math.pi / 2; // past the edge-on midpoint
        // The back face is pre-rotated a half-turn so it lands un-mirrored at angle == π.
        final face = showingBack
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..rotateY(math.pi),
                child: widget.back,
              )
            : widget.front;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012) // a little perspective so the turn reads as 3D
            ..rotateY(angle),
          child: face,
        );
      },
    );
  }
}
