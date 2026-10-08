// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The content of the pop-out window: one feed, the two call controls on hover,
/// and, when the window is borderless, its own drag region, edges and close.
///
/// It renders the same `screenShareViewFor`/`cameraViewFor` widget the call
/// screen and mini-player render, in the same engine, so the pop-out is a
/// reparent and never a second subscription. Density follows this window's own
/// width, not the main window's and not the platform
/// (docs/design/desktop-vs-mobile.md, law 1 and law 2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../desktop/desktop_window_port.dart' show ResizeEdge;
import '../desktop/window_resize_frame.dart';
import '../providers/call_mini_player.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';

const popOutWindowKey = Key('popout_window_view');
const popOutDragRegionKey = Key('popout_drag_region');

class PopOutWindowView extends ConsumerWidget {
  const PopOutWindowView({super.key, required this.feed, this.frame});

  final MiniPlayerFeed feed;

  /// Null when the window keeps its OS decorations.
  final PopOutFrame? frame;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(voiceControllerProvider.notifier);
    final micOn = ref.watch(
      voiceFlagsProvider.select((f) => f.microphoneEnabled),
    );
    final view = switch (feed.kind) {
      FeedKind.screenShare => controller.screenShareViewFor(feed.identity),
      FeedKind.camera => controller.cameraViewFor(feed.identity),
    };
    final label = switch (feed.kind) {
      FeedKind.screenShare => "${feed.name}'s screen",
      FeedKind.camera => feed.name,
    };

    // The window root has no Navigator above it, and tooltips need an Overlay.
    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (context) => Material(
            key: popOutWindowKey,
            color: Colors.black,
            child: _HoverReveal(
              builder: (shown) => Stack(
                fit: StackFit.expand,
                children: [
                  view,
                  if (frame != null) _TopBar(label: label, frame: frame!),
                  _Controls(
                    shown: shown,
                    micOn: micOn,
                    onMute: controller.toggleMicrophone,
                    onLeave: controller.leave,
                  ),
                  if (frame != null)
                    ResizeHandles(onStart: frame!.onResizeStart),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// What the borderless window needs from its host: the window has no title bar
/// of its own, so the content supplies the drag region, the edges and a close.
class PopOutFrame {
  const PopOutFrame({
    required this.onMoveStart,
    required this.onResizeStart,
    required this.onClose,
  });

  final VoidCallback onMoveStart;
  final void Function(ResizeEdge edge) onResizeStart;
  final VoidCallback onClose;
}

/// Shows its overlay controls while the pointer is over the window or focus is
/// inside it, so a keyboard user can still reach them.
class _HoverReveal extends StatefulWidget {
  const _HoverReveal({required this.builder});

  final Widget Function(bool shown) builder;

  @override
  State<_HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<_HoverReveal> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: widget.builder(_hovered || _focused),
    ),
  );
}

const _revealDuration = Duration(milliseconds: 150);

class _TopBar extends StatelessWidget {
  const _TopBar({required this.label, required this.frame});

  final String label;
  final PopOutFrame frame;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: kWindowResizeHandleThickness,
      left: kWindowResizeHandleThickness,
      right: kWindowResizeHandleThickness,
      child: Row(
        children: [
          Expanded(
            child: Listener(
              key: popOutDragRegionKey,
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => frame.onMoveStart(),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.s8),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.micro.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Close pop-out',
            tooltip: 'Close pop-out',
            onPressed: frame.onClose,
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.shown,
    required this.micOn,
    required this.onMute,
    required this.onLeave,
  });

  final bool shown;
  final bool micOn;
  final VoidCallback onMute;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: AppSpacing.s8,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: _revealDuration,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: AppSpacing.s16,
          children: [
            AppIconButton(
              icon: micOn ? AppIcons.mic : AppIcons.micOff,
              semanticLabel: micOn ? 'Mute' : 'Unmute',
              tooltip: micOn ? 'Mute' : 'Unmute',
              onPressed: onMute,
            ),
            AppIconButton(
              icon: AppIcons.leaveCall,
              semanticLabel: 'Leave call',
              tooltip: 'Leave call',
              variant: AppIconButtonVariant.danger,
              onPressed: onLeave,
            ),
          ],
        ),
      ),
    );
  }
}
