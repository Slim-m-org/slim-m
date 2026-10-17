// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The chip that names what a video is showing, and the pointer-gated
/// reveal that keeps it out of the way until asked for.
///
/// Distinct from `hover_reveal.dart`'s [HoverReveal], which tracks hover for
/// a message row and hands it to a builder: this one answers the different
/// question of whether there is a pointer at all. Hover is an input
/// capability rather than a width, the one case
/// `docs/design/desktop-vs-mobile.md`'s width-not-platform rule does not
/// settle by itself - where nothing can hover, hiding the label would simply
/// lose it, so [PointerRevealed] reads `mouseIsConnected` rather than the
/// platform and stays shown when no mouse is attached.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:slimm_design_system/design_system.dart';

/// Reports whether a pointer is over this region, so a caller can reveal
/// chrome only while it is.
///
/// The hover region is whatever [builder] returns - the whole tile, not the
/// label - because a label that only appeared while the pointer was over the
/// label itself could never be reached: it starts invisible.
///
/// `revealed` is also true where there is no pointer to hover with, and
/// where [interactive] is false: a tile behind an `IgnorePointer` never
/// receives an enter event, so hiding its label would hide it for good.
class PointerRevealed extends StatefulWidget {
  const PointerRevealed({
    super.key,
    required this.builder,
    this.interactive = true,
  });

  final Widget Function(BuildContext context, bool revealed) builder;

  /// False where this subtree cannot receive pointer events at all.
  final bool interactive;

  @override
  State<PointerRevealed> createState() => _PointerRevealedState();
}

class _PointerRevealedState extends State<PointerRevealed> {
  bool _hovering = false;
  late bool _mouseConnected =
      RendererBinding.instance.mouseTracker.mouseIsConnected;

  void _onMouseTrackerChanged() {
    final connected = RendererBinding.instance.mouseTracker.mouseIsConnected;
    if (connected == _mouseConnected) return;
    setState(() => _mouseConnected = connected);
  }

  @override
  void initState() {
    super.initState();
    RendererBinding.instance.mouseTracker.addListener(_onMouseTrackerChanged);
  }

  @override
  void dispose() {
    RendererBinding.instance.mouseTracker.removeListener(
      _onMouseTrackerChanged,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final revealed = !widget.interactive || !_mouseConnected || _hovering;
    final content = widget.builder(context, revealed);
    if (!widget.interactive) return content;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: content,
    );
  }
}

/// Fades [child] in and out on [revealed], so every caller of
/// [PointerRevealed] animates its chrome the same way.
class RevealFade extends StatelessWidget {
  const RevealFade({super.key, required this.revealed, required this.child});

  final bool revealed;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: revealed ? 1 : 0,
    duration: AppMotion.reduced(context, AppMotion.fast),
    child: child,
  );
}

/// The small translucent chip naming what a video shows, sized to sit inside
/// the video rather than beside it.
class MediaLabelChip extends StatelessWidget {
  const MediaLabelChip({
    super.key,
    required this.label,
    required this.icon,
    this.iconColor,
  });

  final String label;
  final IconData icon;

  /// Defaults to the accent, which is how a live mic or share reads.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: tokens.surfaceBase.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadii.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: iconColor ?? tokens.accent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
