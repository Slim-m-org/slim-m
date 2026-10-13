// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A generic OS-file drop target: a visible overlay while a drag is over it,
/// and one callback with whatever landed. Callers (the channel view, the
/// emoji card, `ImageDropZone`) never invent their own drag handling; they
/// only decide what a drop means for them.
///
/// See `docs/dependencies.md` for why `desktop_drop` over
/// `super_drag_and_drop`, and why this needs no `dart.library.*` conditional
/// import the way a desktop-only plugin would.
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Whether this platform delivers OS drag-and-drop events at all: every
/// desktop target, and a browser regardless of the host OS underneath it.
///
/// Never `Platform.isX`: `dart:io`'s `Platform` throws outright on web,
/// which is exactly the case this must still answer true for. This is a
/// capability check, not a layout one - see
/// `docs/design/desktop-vs-mobile.md`'s own rule that a platform check is
/// only ever for what a platform can do, never for how something looks.
bool dropZoneSupported() =>
    kIsWeb ||
    switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };

/// Wraps [child] with an OS file drop target.
///
/// [enabled] false disables the target outright rather than accepting a
/// drop only to refuse it: a drop the caller cannot honour (a read-only
/// channel, a busy import) should never look like it might work. On a
/// platform [dropZoneSupported] says has no drag-and-drop input at all,
/// this renders [child] alone - mounting `DropTarget` there is harmless
/// (see the module doc), but the overlay machinery has nothing to listen
/// for either way.
class AppDropZone extends StatefulWidget {
  const AppDropZone({
    super.key,
    required this.enabled,
    required this.label,
    required this.icon,
    required this.onDrop,
    required this.child,
  });

  final bool enabled;

  /// What a drop here will do, shown on the overlay while one is in
  /// progress: "Drop to attach", "Drop to import emoji".
  final String label;
  final IconData icon;
  final ValueChanged<List<DropItem>> onDrop;
  final Widget child;

  @override
  State<AppDropZone> createState() => _AppDropZoneState();
}

class _AppDropZoneState extends State<AppDropZone> {
  bool _dragging = false;

  void _setDragging(bool value) {
    if (_dragging != value) setState(() => _dragging = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!dropZoneSupported()) return widget.child;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => _setDragging(true),
      onDragExited: (_) => _setDragging(false),
      onDragDone: (details) {
        _setDragging(false);
        widget.onDrop(details.files);
      },
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: AppDropOverlay(label: widget.label, icon: widget.icon),
            ),
        ],
      ),
    );
  }
}

/// The least height the icon-above-label overlay fits in, with room to breathe.
const double _stackedHeight = 72;

/// What a drop target shows while a drag is over it: the zone's [label] and
/// [icon] on a raised, accent-bordered fill.
class AppDropOverlay extends StatelessWidget {
  const AppDropOverlay({super.key, required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: 1,
        duration: AppMotion.reduced(context, AppMotion.fast),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised.withValues(alpha: 0.92),
            border: Border.all(color: tokens.accent, width: 2),
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          // A short target, such as one settings row, puts the icon beside the label instead of above it.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final short = constraints.maxHeight < _stackedHeight;
              final glyph = Icon(
                icon,
                size: short ? AppSizes.icon16 : AppSizes.icon24,
                color: tokens.accent,
              );
              final text = Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              );
              return Center(
                child: short
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          glyph,
                          const SizedBox(width: AppSpacing.s8),
                          Flexible(child: text),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          glyph,
                          const SizedBox(height: AppSpacing.s8),
                          text,
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}
