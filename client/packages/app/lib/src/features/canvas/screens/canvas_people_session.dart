// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the one people panel reads: who is on the canvas, who this device follows, and the follow and summon actions.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_follow_targets.dart';
import 'canvas_view_relay.dart';

/// Notifies only when the people, the followed person or the view mode change, never for a cursor that just moved.
class CanvasPeopleSession extends ChangeNotifier {
  CanvasPeopleSession({
    required this.relay,
    required this.cursors,
    required this.selfId,
    required this.viewMode,
    required this.onBringEveryone,
  }) {
    cursors.addListener(_refresh);
    relay.following.addListener(_refresh);
    viewMode?.addListener(_refresh);
    _onCanvas = _compute();
    _followed = relay.following.value;
    _canBringEveryone = !(viewMode?.personal ?? false);
  }

  final CanvasViewRelay relay;
  final CanvasCursors cursors;
  final String? Function() selfId;
  final CanvasViewMode? viewMode;
  final VoidCallback onBringEveryone;

  List<CanvasFollowTarget> _onCanvas = const [];
  String? _followed;
  bool _canBringEveryone = true;
  bool _disposed = false;

  /// Everyone with a cursor on the board but this device, in a stable order.
  List<CanvasFollowTarget> get onCanvas => _onCanvas;

  String? get followed => _followed;

  /// False in the personal view, whose camera is never relayed (decision 0082).
  bool get canBringEveryone => _canBringEveryone;

  /// The followed person's cursor colour, so the outline and their avatar share it.
  Color? get followedColor {
    final id = _followed;
    if (id == null) return null;
    final cursor = cursors.all.where((c) => c.id == id).firstOrNull;
    if (cursor == null) return null;
    return AppCanvasColors.cursors[cursor.colorIndex %
        AppCanvasColors.cursors.length];
  }

  void toggleFollow(String userId) =>
      _followed == userId ? relay.stopFollowing() : relay.follow(userId);

  void stopFollowing() => relay.stopFollowing();

  List<CanvasFollowTarget> _compute() => canvasFollowTargets(
    cursors: cursors.all,
    participants: const [],
    selfId: selfId(),
  );

  // Cursor frames arrive at pointer rate; only who is on the board matters here.
  void _refresh() {
    if (_disposed) return;
    final people = _compute();
    final followed = relay.following.value;
    final canBring = !(viewMode?.personal ?? false);
    final same =
        canBring == _canBringEveryone &&
        followed == _followed &&
        people.length == _onCanvas.length &&
        [for (var i = 0; i < people.length; i++) i].every(
          (i) =>
              people[i].id == _onCanvas[i].id &&
              people[i].name == _onCanvas[i].name,
        );
    _onCanvas = people;
    _followed = followed;
    _canBringEveryone = canBring;
    if (!same) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cursors.removeListener(_refresh);
    relay.following.removeListener(_refresh);
    viewMode?.removeListener(_refresh);
    super.dispose();
  }
}

/// Hands one [CanvasPeopleSession] to the panel, the chip and the outline below it.
class CanvasPeopleScope extends InheritedNotifier<CanvasPeopleSession> {
  const CanvasPeopleScope({super.key, super.notifier, required super.child});

  /// Null when follow is not wired (no relay or cursors), which leaves a plain call roster.
  static CanvasPeopleSession? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CanvasPeopleScope>()?.notifier;
}

/// Builds the session from the pane's relay and cursors, and keeps it in step with them.
class CanvasPeopleHost extends StatefulWidget {
  const CanvasPeopleHost({
    super.key,
    required this.relay,
    required this.cursors,
    required this.selfId,
    required this.viewMode,
    required this.onBringEveryone,
    required this.child,
  });

  final CanvasViewRelay? relay;
  final CanvasCursors? cursors;
  final String? selfId;
  final CanvasViewMode? viewMode;
  final VoidCallback onBringEveryone;
  final Widget child;

  @override
  State<CanvasPeopleHost> createState() => _CanvasPeopleHostState();
}

class _CanvasPeopleHostState extends State<CanvasPeopleHost> {
  CanvasPeopleSession? _session;

  CanvasPeopleSession? _build() {
    final relay = widget.relay;
    final cursors = widget.cursors;
    if (relay == null || cursors == null) return null;
    return CanvasPeopleSession(
      relay: relay,
      cursors: cursors,
      selfId: () => widget.selfId,
      viewMode: widget.viewMode,
      onBringEveryone: widget.onBringEveryone,
    );
  }

  @override
  void initState() {
    super.initState();
    _session = _build();
  }

  @override
  void didUpdateWidget(covariant CanvasPeopleHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.relay != widget.relay ||
        oldWidget.cursors != widget.cursors ||
        oldWidget.viewMode != widget.viewMode) {
      _session?.dispose();
      _session = _build();
    }
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      CanvasPeopleScope(notifier: _session, child: widget.child);
}
