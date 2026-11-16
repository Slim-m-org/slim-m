// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A generic OS-file drop target: a visible overlay while a drag is over it,
/// and one callback with whatever landed and where. Callers (the channel view,
/// the emoji card, `ImageDropZone`, a shared screen's tile) never invent their
/// own drag handling; they only decide what a drop means for them.
///
/// The plugin tells every target under the pointer, so a zone inside another
/// takes the drops that land on it and the outer one leaves them alone.
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

  /// What landed, and where in this zone's own coordinates.
  final void Function(List<DropItem> items, Offset at) onDrop;
  final Widget child;

  @override
  State<AppDropZone> createState() => _AppDropZoneState();
}

class _AppDropZoneState extends State<AppDropZone> {
  bool _dragging = false;
  _AppDropZoneState? _outer;
  final _inner = <_AppDropZoneState>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final outer = context
        .dependOnInheritedWidgetOfExactType<_DropZoneScope>()
        ?.zone;
    if (outer == _outer) return;
    _outer?._inner.remove(this);
    _outer = outer?.._inner.add(this);
  }

  @override
  void dispose() {
    _outer?._inner.remove(this);
    super.dispose();
  }

  /// Whether a drop at [global] is this zone's to take.
  bool _takes(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (!widget.enabled || box == null || !box.attached) return false;
    return box.paintBounds.contains(box.globalToLocal(global));
  }

  bool _innerTakes(Offset global) => _inner.any((zone) => zone._takes(global));

  void _setDragging(bool value) {
    if (_dragging != value) setState(() => _dragging = value);
  }

  void _hover(DropEventDetails details) =>
      _setDragging(!_innerTakes(details.globalPosition));

  @override
  Widget build(BuildContext context) {
    if (!dropZoneSupported()) return widget.child;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: _hover,
      onDragUpdated: _hover,
      onDragExited: (_) => _setDragging(false),
      onDragDone: (details) {
        _setDragging(false);
        if (_innerTakes(details.globalPosition)) return;
        widget.onDrop(details.files, details.localPosition);
      },
      child: _DropZoneScope(
        zone: this,
        child: Stack(
          children: [
            widget.child,
            if (_dragging)
              Positioned.fill(
                child: AppDropOverlay(label: widget.label, icon: widget.icon),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lets a zone find the one it sits inside, so the outer zone can leave it its drops.
class _DropZoneScope extends InheritedWidget {
  const _DropZoneScope({required this.zone, required super.child});

  final _AppDropZoneState zone;

  @override
  bool updateShouldNotify(_DropZoneScope old) => old.zone != zone;
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
      child: AppFadeIn(
        offset: 0,
        duration: AppMotion.fast,
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
