// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls of the camera and screen-share tiles for everyone on this call, in the canvas's world space over [CanvasSurface].
/// The video paints in `CanvasPresenceBackdrop` under the ink; this layer carries gestures and chrome and decides which remote video to subscribe to ([onVideoInterest]).
/// Design: docs/decisions/0010-canvas-media-tiles.md, 0081 and 0086.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'package:slimm_design_system/design_system.dart';

import '../../messages/widgets/media_label.dart';
import '../../voice/widgets/call_roster_motion.dart';
import 'canvas_presence_bubble.dart';
import 'canvas_presence_frame.dart';
import 'canvas_presence_geometry.dart';
import 'canvas_presence_tile.dart';

export 'canvas_presence_backdrop.dart';
export 'canvas_presence_bubble.dart';
export 'canvas_presence_geometry.dart'
    show CameraViewBuilder, ScreenShareViewBuilder;

/// Every camera and screen-share tile, world-anchored and draggable, resizable, lockable and hideable through [overrides]; renders nothing when no feed is up.
class CanvasPresenceLayer extends StatefulWidget {
  const CanvasPresenceLayer({
    super.key,
    required this.document,
    required this.participants,
    required this.overrides,
    required this.onCommit,
    this.onVideoInterest,
    this.hideSelfCamera = false,
    this.layout = const CanvasPresenceLayout(),
    this.tool = CanvasTool.pan,
    this.participantMenuItemsBuilder,
    this.resolver,
    this.focusedKey,
    this.onFocus,
    this.onPointerMoved,
  });

  /// Relays this device's pointer over a tile, which the surface beneath it cannot see.
  final PointerMoved? onPointerMoved;

  /// The tile the camera is fitted to; the backdrop shows its video and it takes no controls, so a drag cannot move it.
  final String? focusedKey;

  /// Asks the pane to focus a tile's feed; null leaves the tiles without the control.
  final ValueChanged<String>? onFocus;

  /// Shared with `CanvasPresenceBackdrop` so both resolve the tiles through
  /// one visibility history; a standalone layer makes its own.
  final CanvasPresenceFrameResolver? resolver;

  final CanvasDocument document;
  final List<VoiceParticipant> participants;
  final CanvasPresenceTileOverrides overrides;

  /// The canvas's active tool, forwarded to every tile; anything but [CanvasTool.pan] makes a tile transparent to a pointer (see `canvas_presence_tile.dart`).
  /// Defaults to pan so a caller with no notion of tools keeps tiles interactive.
  final CanvasTool tool;

  /// Sends [overrides]' current answer for one tile key onward to the
  /// server - see `CanvasMediaSlotSync.commit` in the app's own canvas
  /// screen, which is what this closes over. Fired once a drag or resize
  /// settles, and immediately on a lock or depth toggle; never fired for
  /// [overrides.setHidden], which needs no commit at all.
  final void Function(String key, Rect rect) onCommit;

  /// Reports the tile keys showing live video so the rest are unsubscribed,
  /// after the frame and only on change. Null means no opinion (no roster
  /// here, or disposed), so a canvas never culls a call it is not showing.
  final void Function(Set<String>? tileKeys)? onVideoInterest;

  /// The caller's own standing "never show my own camera" preference
  /// (`canvas_self_presence.dart`), layered on top of whatever
  /// [overrides] says for `camera:<selfId>` - distinct from a per-call hide,
  /// since this one is meant to survive a rejoin rather than reset with it.
  /// Never suppresses a self screen-share tile: that preference is about a
  /// face, not about whatever this device is sharing.
  final bool hideSelfCamera;
  final CanvasPresenceLayout layout;

  /// This tile's own quick-actions rows - volume, mute for me, view
  /// profile, moderate - for whichever participant a tile belongs to; null
  /// renders no extra rows at all, and this device's own tile never gets
  /// any regardless (`participant_call_menu.dart`'s own
  /// `participantCallMenuItems` already answers empty for `isLocal`).
  final List<Widget> Function(
    BuildContext context,
    VoiceParticipant participant,
    VoidCallback close,
  )?
  participantMenuItemsBuilder;

  @override
  State<CanvasPresenceLayer> createState() => _CanvasPresenceLayerState();
}

class _CanvasPresenceLayerState extends State<CanvasPresenceLayer> {
  late final CanvasPresenceFrameResolver _resolver =
      widget.resolver ?? CanvasPresenceFrameResolver();
  Set<String>? _lastReported;
  // Distinct from `_lastReported == null`, which is itself a real answer.
  bool _reported = false;
  bool _deliveryScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.document.addListener(_onDocumentChanged);
    widget.overrides.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant CanvasPresenceLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      oldWidget.document.removeListener(_onDocumentChanged);
      widget.document.addListener(_onDocumentChanged);
    }
    if (oldWidget.overrides != widget.overrides) {
      oldWidget.overrides.removeListener(_onChanged);
      widget.overrides.addListener(_onChanged);
    }
    // After this frame, not inside didUpdateWidget: overrides is shared with the dock's own still-mid-reconciliation ListenableBuilder, and notifyListeners() reaching it here throws "setState() called during build".
    final overrides = widget.overrides;
    final keys = presenceTileKeys(widget.participants);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // An empty roster is a reconnect in progress; pruning then would forget every hidden tile.
      if (mounted && widget.overrides == overrides && keys.isNotEmpty) {
        overrides.prune(keys);
      }
    });
  }

  @override
  void dispose() {
    widget.document.removeListener(_onDocumentChanged);
    widget.overrides.removeListener(_onChanged);
    // Synchronously: there is no later frame of this widget's own to ride, and a stale interest set outliving it would keep culling a call nothing here is looking at.
    widget.onVideoInterest?.call(null);
    super.dispose();
  }

  final _viewGate = CanvasViewChangeGate();

  void _onDocumentChanged() {
    if (mounted && _viewGate.changed(widget.document)) setState(() {});
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final frame = _resolver.resolve(
      participants: widget.participants,
      document: widget.document,
      overrides: widget.overrides,
      layout: widget.layout,
      hideSelfCamera: widget.hideSelfCamera,
    );
    final byIdentity = frame.byIdentity;
    final onCanvas = frame.onCanvas;
    final visibleIds = frame.visibleIds;
    if (frame.keys.isEmpty) {
      _reportInterest(null);
      return const SizedBox.shrink();
    }
    if (onCanvas.isEmpty) {
      _reportInterest(const <String>{});
      return const SizedBox.shrink();
    }
    // Checked against onCanvas rather than trusted: a participant who left leaves a key nothing can subscribe to. The focused feed stays subscribed wherever its tile sits.
    final focused = widget.focusedKey;
    final wantsVideo = focused != null && onCanvas.containsKey(focused)
        ? {...visibleIds, focused}
        : visibleIds;
    _reportInterest(wantsVideo);
    if (visibleIds.isEmpty) return const SizedBox.shrink();
    final camera = widget.document.camera;
    final painted = presencePaintOrder(
      visibleIds.where((key) => key != widget.focusedKey).toSet(),
      widget.overrides.zFor,
    );
    // After the board and the dock in Tab order; see canvas_pane_body.dart.
    return FocusTraversalOrder(
      order: const NumericFocusOrder(3),
      child: CanvasBoardClip(
        document: widget.document,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final key in painted)
              if (_tile(key, onCanvas[key]!, camera, byIdentity)
                  case final tile?)
                tile,
            if (focused != null && onCanvas[focused] != null)
              ?_focusedLabel(focused, onCanvas[focused]!, camera, byIdentity),
          ],
        ),
      ),
    );
  }

  /// Records what this build resolved and, if it differs from the last delivery, schedules one post-frame delivery.
  /// The set is read again inside the callback, so two builds before the frame deliver only the newer answer.
  void _reportInterest(Set<String>? keys) {
    if (_reported && _sameAsLast(keys)) return;
    _reported = true;
    _lastReported = keys == null ? null : Set<String>.unmodifiable(keys);
    if (_deliveryScheduled) return;
    _deliveryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deliveryScheduled = false;
      if (mounted) widget.onVideoInterest?.call(_lastReported);
    });
  }

  bool _sameAsLast(Set<String>? keys) {
    if (keys == null || _lastReported == null) {
      return keys == null && _lastReported == null;
    }
    return setEquals(keys, _lastReported);
  }

  static String _semanticLabel(VoiceParticipant participant, bool isScreen) {
    if (!isScreen) {
      return participant.isLocal
          ? "Your camera, on this call's canvas"
          : "${participant.name}'s camera, on this call's canvas";
    }
    if (participant.isLocal) return "Your screen share, on this call's canvas";
    return "${participant.name}'s screen share, on this call's canvas";
  }

  Widget _tileBadge(VoiceParticipant participant, bool isScreen) => isScreen
      ? CanvasScreenShareBadge(participant: participant)
      : CanvasCameraBadge(participant: participant);

  List<Widget> Function(BuildContext, VoidCallback)? _participantItemsBuilder(
    VoiceParticipant participant,
  ) {
    final builder = widget.participantMenuItemsBuilder;
    if (builder == null) return null;
    return (tileContext, close) => builder(tileContext, participant, close);
  }

  // The tile's own controls are left out while focused, so its name is the one thing laid over the video.
  Widget? _focusedLabel(
    String key,
    Rect rect,
    Camera camera,
    Map<String, VoiceParticipant> byIdentity,
  ) {
    final participant = byIdentity[presenceTileIdentity(key)];
    if (participant == null) return null;
    final isScreen = presenceTileKind(key) == screenTrackKind;
    final screen = presenceScreenRect(rect, camera);
    return Positioned(
      left: math.max(screen.left, 0) + AppSpacing.s12,
      top: math.max(screen.top, 0) + _clearOfCornerRows(context),
      child: IgnorePointer(
        child: MediaLabelChip(
          icon: isScreen ? AppIcons.screenShare : AppIcons.camera,
          label: _mediaChipLabel(isScreen, participant),
        ),
      ),
    );
  }

  // The view pill and zoom pill sit in the same corner, so the chip starts below them.
  double _clearOfCornerRows(BuildContext context) {
    final row = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.icon28;
    final top = math.max(MediaQuery.paddingOf(context).top, AppSpacing.s12);
    return top + 2 * (row + AppSpacing.s8);
  }

  String _mediaChipLabel(bool isScreen, VoiceParticipant participant) {
    if (isScreen) return presenceScreenLabel(participant);
    return participant.isLocal ? 'Your camera' : participant.name;
  }

  Widget? _tile(
    String key,
    Rect rect,
    Camera camera,
    Map<String, VoiceParticipant> byIdentity,
  ) {
    final isScreen = presenceTileKind(key) == screenTrackKind;
    final identity = presenceTileIdentity(key);
    final participant = byIdentity[identity];
    if (participant == null) return null;
    final locked = widget.overrides.stateFor(key).locked;
    // Never null: the override's own rect once set, this build's resolved default otherwise.
    void commit() =>
        widget.onCommit(key, widget.overrides.stateFor(key).rect ?? rect);
    return CanvasPresenceManipulableTile(
      key: ValueKey(key),
      worldRect: rect,
      camera: camera,
      locked: locked,
      tool: widget.tool,
      document: widget.document,
      onRectChanged: (next) => widget.overrides.setRect(key, next),
      onRectCommitted: commit,
      onToggleLocked: widget.overrides.personal
          ? null
          : () {
              widget.overrides.setLocked(key, !locked);
              commit();
            },
      onHide: () => widget.overrides.setHidden(key, true),
      participantItemsBuilder: _participantItemsBuilder(participant),
      onPointerMoved: widget.onPointerMoved,
      personal: widget.overrides.personal,
      onExpand: widget.onFocus == null ? null : () => widget.onFocus!(key),
      semanticLabel: _semanticLabel(participant, isScreen),
      child: CallTilePop(child: _tileBadge(participant, isScreen)),
    );
  }
}
