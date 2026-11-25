// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the one people panel reads: who is on the canvas, who this device follows, and the follow and summon actions.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../members/providers/blocks_controller.dart';
import '../providers/canvas_viewers.dart';
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
    List<CanvasFollowTarget> viewers = const [],
  }) : _viewers = viewers {
    cursors.addListener(_refresh);
    relay.following.addListener(_refresh);
    viewMode?.addListener(_refresh);
    final cursorPeople = _cursorPeople();
    _followable = {for (final t in cursorPeople) t.id};
    _onCanvas = _compute(cursorPeople);
    _followed = relay.following.value;
    _canBringEveryone = !(viewMode?.personal ?? false);
  }

  final CanvasViewRelay relay;
  final CanvasCursors cursors;
  final String? Function() selfId;
  final CanvasViewMode? viewMode;
  final VoidCallback onBringEveryone;

  List<CanvasFollowTarget> _viewers;
  List<CanvasFollowTarget> _onCanvas = const [];
  Set<String> _followable = const {};
  String? _followed;
  bool _canBringEveryone = true;
  bool _disposed = false;
  ({String id, String name})? _followedName;
  Timer? _graceTimer;

  /// Everyone with the board open, earliest first, then anyone with only a cursor on it; never this device.
  List<CanvasFollowTarget> get onCanvas => _onCanvas;

  /// Whether following [userId] works from the board alone: they have a cursor on it.
  bool isFollowable(String userId) => _followable.contains(userId);

  /// Replaces who has the board open, from the roster.
  void setViewers(List<CanvasFollowTarget> viewers) {
    _viewers = viewers;
    _refresh();
  }

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

  /// The followed person's name as last seen, for the chip while they have no cursor.
  String? get followedName =>
      _followedName?.id == _followed ? _followedName?.name : null;

  void rememberFollowedName(String id, String name) =>
      _followedName = (id: id, name: name);

  /// Asks the widgets to look again after [after], when a kept follow may have run out.
  void recheckAfter(Duration after) {
    _graceTimer?.cancel();
    _graceTimer = Timer(after, () {
      if (!_disposed) notifyListeners();
    });
  }

  void toggleFollow(String userId) =>
      _followed == userId ? relay.stopFollowing() : relay.follow(userId);

  void stopFollowing() => relay.stopFollowing();

  List<CanvasFollowTarget> _cursorPeople() => canvasFollowTargets(
    cursors: cursors.all,
    participants: const [],
    selfId: selfId(),
  );

  List<CanvasFollowTarget> _compute(List<CanvasFollowTarget> cursorPeople) {
    final self = selfId();
    final viewers = [
      for (final v in _viewers)
        if (v.id != self) v,
    ];
    final seen = {for (final v in viewers) v.id};
    return [
      ...viewers,
      for (final t in cursorPeople)
        if (!seen.contains(t.id)) t,
    ];
  }

  // Cursor frames arrive at pointer rate; only who is on the board matters here.
  void _refresh() {
    if (_disposed) return;
    final cursorPeople = _cursorPeople();
    final followable = {for (final t in cursorPeople) t.id};
    final people = _compute(cursorPeople);
    final followed = relay.following.value;
    final canBring = !(viewMode?.personal ?? false);
    final same =
        canBring == _canBringEveryone &&
        followable.length == _followable.length &&
        followable.containsAll(_followable) &&
        followed == _followed &&
        people.length == _onCanvas.length &&
        [for (var i = 0; i < people.length; i++) i].every(
          (i) =>
              people[i].id == _onCanvas[i].id &&
              people[i].name == _onCanvas[i].name,
        );
    _onCanvas = people;
    _followable = followable;
    _followed = followed;
    _canBringEveryone = canBring;
    if (!same) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _graceTimer?.cancel();
    cursors.removeListener(_refresh);
    relay.following.removeListener(_refresh);
    viewMode?.removeListener(_refresh);
    super.dispose();
  }
}

/// Hands one [CanvasPeopleSession] to the panel, the chip and the outline below it.
class CanvasPeopleScope extends InheritedNotifier<CanvasPeopleSession> {
  const CanvasPeopleScope({
    super.key,
    super.notifier,
    this.channelId,
    required super.child,
  });

  /// The canvas channel being viewed, which decides whose call roster belongs on it.
  final String? channelId;

  static String? channelIdOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CanvasPeopleScope>()
      ?.channelId;

  @override
  bool updateShouldNotify(CanvasPeopleScope oldWidget) =>
      super.updateShouldNotify(oldWidget) || channelId != oldWidget.channelId;

  /// Null when follow is not wired (no relay or cursors), which leaves a plain call roster.
  static CanvasPeopleSession? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CanvasPeopleScope>()?.notifier;
}

/// Builds the session from the pane's relay and cursors, and keeps it in step with them and with who has the board open.
class CanvasPeopleHost extends ConsumerStatefulWidget {
  const CanvasPeopleHost({
    super.key,
    required this.relay,
    required this.cursors,
    required this.selfId,
    required this.viewMode,
    required this.onBringEveryone,
    required this.child,
    this.channelId,
  });

  final CanvasViewRelay? relay;
  final CanvasCursors? cursors;
  final String? selfId;
  final CanvasViewMode? viewMode;
  final VoidCallback onBringEveryone;
  final Widget child;
  final String? channelId;

  @override
  ConsumerState<CanvasPeopleHost> createState() => _CanvasPeopleHostState();
}

class _CanvasPeopleHostState extends ConsumerState<CanvasPeopleHost> {
  CanvasPeopleSession? _session;
  List<CanvasFollowTarget> _viewers = const [];
  ProviderSubscription<List<CanvasViewerPerson>>? _people;
  ProviderSubscription<CanvasViewersState>? _arrivals;

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
      viewers: _viewers,
    );
  }

  void _listen() {
    final channelId = widget.channelId;
    _people?.close();
    _arrivals?.close();
    if (channelId == null) return;
    _people = ref.listenManual(canvasViewerPeopleProvider(channelId), (
      _,
      next,
    ) {
      _viewers = [for (final p in next) CanvasFollowTarget(p.id, p.name)];
      _session?.setViewers(_viewers);
    }, fireImmediately: true);
    _arrivals = ref.listenManual(canvasViewersProvider, (previous, next) {
      if (previous == null || !previous.loaded) return;
      final before = {for (final v in previous.of(channelId)) v.userId};
      final blocked = ref.read(blocksProvider);
      for (final v in next.of(channelId)) {
        if (before.contains(v.userId) ||
            v.userId == widget.selfId ||
            blocked.contains(v.userId)) {
          continue;
        }
        ref.read(canvasViewerArrivalProvider.notifier).state =
            CanvasViewerArrival(channelId, v.userId);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _listen();
    _session = _build();
  }

  @override
  void didUpdateWidget(covariant CanvasPeopleHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId) _listen();
    if (oldWidget.relay != widget.relay ||
        oldWidget.cursors != widget.cursors ||
        oldWidget.viewMode != widget.viewMode) {
      _session?.dispose();
      _session = _build();
    }
  }

  @override
  void dispose() {
    _people?.close();
    _arrivals?.close();
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CanvasPeopleScope(
    notifier: _session,
    channelId: widget.channelId,
    child: widget.child,
  );
}
