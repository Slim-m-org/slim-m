// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Camera and screen-share tiles for whoever is on this channel's call -
/// including the caller's own - positioned in the canvas's own
/// world-coordinate space, exactly the AR-glasses framing the owner asked
/// for: "make the screen as big or small as you want, draw on it, hide it,
/// lock it in place."
///
/// A widget layer stacked over [CanvasSurface], never painted into it: a
/// live camera or screen-share track is a platform `Texture`
/// (`VoiceSession.cameraViewFor`/`screenShareViewFor` already return one
/// wrapped as a plain `Widget`, per their own docs), and there is no
/// supported way to sample a `Texture`'s pixels into a `CustomPainter`'s
/// `Canvas` without an expensive manual frame capture this package does not
/// do anywhere else. So presence is the topmost layer in its own `Stack`
/// entry, exactly the shape `docs/STRATEGY.md` names: "a presence
/// video-texture layer so LiveKit's video updates never trigger stroke or
/// image repaints."
///
/// **Every tile is presence, never a [CanvasObjectKind]**, and that is a
/// decision recorded in `docs/decisions/0010-canvas-media-tiles.md`, not an
/// oversight: STRATEGY already called camera bubbles and screen-share tiles
/// "ephemeral presence objects never written to the op log and reset on
/// rejoin", and this file extends that same line to position, size, lock and
/// depth, kept in [CanvasPresenceTileOverrides] rather than a
/// `canvas_objects` row. Position, size, lock and depth are shared and
/// persistent now - decision 0010's own reversal of its first call, mirrored
/// from the server's `canvas_media_slots` table by `CanvasMediaSlotSync` in
/// the app's own canvas screen. Only [CanvasPresenceTileOverrides.hidden]
/// stays personal and per-call; see that class's own doc for why.
///
/// This used to render the caller's own bubble nowhere at all (a separate,
/// screen-anchored overlay owned that), which is exactly the "stuck to the
/// dock" complaint the owner reported: a fixed screen corner blocks whatever
/// world content happens to pan underneath it, forever, rather than sitting
/// at one place a person chose. Self and remote are one list now.
///
/// **Sending a tile to the back never moves this widget, or any tile's own
/// controls with it.** A rendered probe proved the obvious version of that
/// feature - reordering the whole manipulable tile below [CanvasSurface] in
/// the pane's Stack - does not merely dim a control, it deletes it:
/// [CanvasSurface] covers its full bounds with an opaque `MouseRegion` for
/// pan and draw, and Flutter's own Stack hit-testing stops at the first
/// child claiming a hit, topmost first, so nothing painted behind it is ever
/// hit-tested again. `CanvasPresenceBackdrop` is the fix: only a
/// sent-to-back tile's *content* (its video, its name badge) moves into that
/// separate, non-interactive, `IgnorePointer`-wrapped widget, painted before
/// [CanvasSurface] so real ink lands over it; the drag area, resize grip and
/// corner controls stay here, at the same screen position, regardless of
/// depth - the same "never a dead end" guarantee `locked` already makes for
/// its own unlock button.
///
/// **This widget is also the one place that decides which remote video the
/// call is worth subscribing to at all**, through [onVideoInterest]. Not a
/// second, parallel declaration of what is on screen: it reports exactly the
/// set it just used to build its own children, so the thing that mounts a
/// video widget and the thing that asks the SFU for that video can never
/// disagree about which tiles those are. [CanvasPresenceBackdrop] needs no
/// report of its own for the same reason - it reads the same
/// `CanvasPresenceFrame` this widget does and then narrows to
/// the sent-to-back subset, so the union of tiles carrying real video across
/// both widgets is precisely this widget's own visible set.
///
/// **Full screen is `showFullscreenVideo`'s existing route, never a second
/// fullscreen of this pane's own.** A tile's expand control pushes the same
/// root-navigator route the voice screen already pushes, so the close
/// button, Escape, the platform back gesture and the self-closing "this feed
/// stopped being live" guard all come with it. Being a *root*-navigator
/// route is also what keeps it from colliding with `canvas_fullscreen.dart`:
/// it sits above `CanvasPane` with its own autofocused `CallbackShortcuts`,
/// so Escape closes the expanded tile and never reaches the pane's own
/// binding underneath, and a canvas already in fullscreen still is when the
/// tile closes.
///
/// What this widget does own is the subscription consequence, because it
/// owns [onVideoInterest] and nothing else may: while a tile is expanded it
/// reports that one key alone, so every other participant's video is
/// unsubscribed for as long as nobody can see it, and restored on close by
/// the ordinary report this widget was already making. Reporting it from
/// inside the route instead would give one interest set two owners, and the
/// one that unmounts first would win.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../widgets/call_roster_motion.dart';
import '../../widgets/fullscreen_video_overlay.dart';
import 'canvas_presence_bubble.dart';
import 'canvas_presence_frame.dart';
import 'canvas_presence_geometry.dart';
import 'canvas_presence_tile.dart';

export 'canvas_presence_backdrop.dart';
export 'canvas_presence_bubble.dart';
export 'canvas_presence_geometry.dart'
    show CameraViewBuilder, ScreenShareViewBuilder;

/// Every call participant's tiles, world-anchored and individually
/// draggable, resizable, lockable and hideable through [overrides] - except
/// an avatar-only tile (camera off, no screen share), which only gets the
/// drag and the hide; see `canvas_presence_tile.dart`'s own doc on
/// `fixedRenderSize`. Renders nothing when [participants] is empty, so a
/// canvas opened on a channel with no active call pays for none of this.
class CanvasPresenceLayer extends StatefulWidget {
  const CanvasPresenceLayer({
    super.key,
    required this.document,
    required this.participants,
    required this.cameraViewFor,
    required this.screenShareViewFor,
    required this.overrides,
    required this.onCommit,
    this.onVideoInterest,
    this.hideSelfCamera = false,
    this.layout = const CanvasPresenceLayout(),
    this.tool = CanvasTool.pan,
    this.participantMenuItemsBuilder,
    this.resolver,
  });

  /// Shared with `CanvasPresenceBackdrop` so both resolve the tiles through
  /// one visibility history; a standalone layer makes its own.
  final CanvasPresenceFrameResolver? resolver;

  final CanvasDocument document;
  final List<VoiceParticipant> participants;
  final CameraViewBuilder cameraViewFor;
  final ScreenShareViewBuilder screenShareViewFor;
  final CanvasPresenceTileOverrides overrides;

  /// The canvas's own active tool, forwarded to every tile - see
  /// `canvas_presence_tile.dart`'s own doc for why anything but
  /// [CanvasTool.pan] makes a tile transparent to a pointer. Defaults to
  /// [CanvasTool.pan] so a caller with no notion of tools (most of this
  /// file's own test suite) keeps every tile fully interactive, unchanged.
  final CanvasTool tool;

  /// Sends [overrides]' current answer for one tile key onward to the
  /// server - see `CanvasMediaSlotSync.commit` in the app's own canvas
  /// screen, which is what this closes over. Fired once a drag or resize
  /// settles, and immediately on a lock or depth toggle; never fired for
  /// [overrides.setHidden], which needs no commit at all.
  final void Function(String key, Rect rect) onCommit;

  /// Reports which tile keys currently carry live video, so the rest can be
  /// unsubscribed rather than merely paused - `VoiceController
  /// .setVideoInterest` is what this closes over.
  ///
  /// Fired after the frame rather than during build, since it reaches out of
  /// this widget into the live session, and only when the set actually
  /// changes, which the spatial hysteresis band already makes rare during an
  /// ordinary pan.
  ///
  /// Reports null - "no opinion, subscribe everything" - rather than an
  /// empty set whenever this canvas has no call roster to speak for, and on
  /// dispose. An empty set is a real answer meaning "nothing on this canvas
  /// wants video", which is what a fully hidden or fully off-screen roster
  /// genuinely is; having no roster at all is not that, and a canvas open on
  /// one channel must not cull a call running in another it knows nothing
  /// about.
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

  /// The tile key currently open full screen over this pane, or null. Local
  /// to this widget rather than shared through [CanvasPresenceTileOverrides]
  /// the way `hidden` is: nobody else on this canvas needs to know, and this
  /// widget already owns the one consequence that matters - see the library
  /// doc above on why interest has exactly one owner.
  String? _expandedKey;

  @override
  void initState() {
    super.initState();
    widget.document.addListener(_onChanged);
    widget.overrides.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant CanvasPresenceLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      oldWidget.document.removeListener(_onChanged);
      widget.document.addListener(_onChanged);
    }
    if (oldWidget.overrides != widget.overrides) {
      oldWidget.overrides.removeListener(_onChanged);
      widget.overrides.addListener(_onChanged);
    }
    // After this frame, not inside didUpdateWidget: overrides is shared with the dock's own still-mid-reconciliation ListenableBuilder, and notifyListeners() reaching it here throws "setState() called during build".
    final overrides = widget.overrides;
    final keys = presenceTileKeys(widget.participants);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.overrides == overrides) overrides.prune(keys);
    });
  }

  @override
  void dispose() {
    widget.document.removeListener(_onChanged);
    widget.overrides.removeListener(_onChanged);
    // Synchronously: there is no later frame of this widget's own to ride, and a stale interest set outliving it would keep culling a call nothing here is looking at.
    widget.onVideoInterest?.call(null);
    super.dispose();
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
    // Checked against onCanvas rather than trusted: a participant who left, or a tile hidden from under the route, leaves a key nothing can subscribe to.
    final expanded = _expandedKey;
    final wantsVideo = expanded != null && onCanvas.containsKey(expanded)
        ? {expanded}
        : visibleIds;
    _reportInterest(wantsVideo);
    if (visibleIds.isEmpty) return const SizedBox.shrink();
    final camera = widget.document.camera;
    final painted = presencePaintOrder(
      visibleIds,
      widget.overrides.zFor,
      (key) => presenceEffectiveSentToBack(key, widget.overrides, byIdentity),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final key in painted)
          if (_tile(key, onCanvas[key]!, camera, byIdentity) case final tile?)
            tile,
      ],
    );
  }

  /// Records what this build resolved and, if that differs from the last
  /// answer delivered, schedules one post-frame delivery of it.
  ///
  /// The set is stored eagerly and read again inside the callback, so a
  /// second build landing before the frame ends delivers the newer answer
  /// once rather than two answers in order.
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

  /// Opens one tile's live feed full screen and narrows video interest to it
  /// for as long as the route is up, restoring the ordinary answer on close.
  ///
  /// The restore rides `finally` rather than the route's own callback so it
  /// still runs when the route is popped by something other than this
  /// widget - Escape, the platform back gesture, or the view closing itself
  /// because the feed stopped being live - none of which report back here.
  Future<void> _expand(
    String key,
    VoiceParticipant participant,
    bool isScreen,
  ) async {
    setState(() => _expandedKey = key);
    try {
      await showFullscreenVideo(
        context,
        identity: participant.identity,
        label: isScreen
            ? presenceScreenLabel(participant)
            : (participant.isLocal ? 'Your camera' : participant.name),
        kind: isScreen
            ? FullscreenVideoKind.screenShare
            : FullscreenVideoKind.camera,
      );
    } finally {
      if (mounted) setState(() => _expandedKey = null);
    }
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
    final avatarOnly = presenceTileIsAvatarOnly(key, byIdentity);
    final state = widget.overrides.stateFor(key);
    // Forced false, never the raw override, for an avatar-only tile - see canvas_presence_geometry.dart's own doc on presenceEffectiveSentToBack for why a stale value from before this camera turned off must not resurface here.
    final locked = !avatarOnly && state.locked;
    final sentToBack = presenceEffectiveSentToBack(
      key,
      widget.overrides,
      byIdentity,
    );
    // Never null: the override's own rect once set, this build's resolved default otherwise.
    void commit() =>
        widget.onCommit(key, widget.overrides.stateFor(key).rect ?? rect);
    return CanvasPresenceManipulableTile(
      key: ValueKey(key),
      worldRect: rect,
      camera: camera,
      locked: locked,
      tool: widget.tool,
      sentToBack: sentToBack,
      fixedRenderSize: avatarOnly ? canvasAvatarMarkerSize : null,
      document: widget.document,
      onRectChanged: (next) => widget.overrides.setRect(key, next),
      onRectCommitted: commit,
      onToggleLocked: avatarOnly
          ? null
          : () {
              widget.overrides.setLocked(key, !locked);
              commit();
            },
      onToggleSentToBack: avatarOnly
          ? null
          : () {
              widget.overrides.setSentToBack(key, !sentToBack);
              commit();
            },
      onHide: () => widget.overrides.setHidden(key, true),
      participantItemsBuilder: widget.participantMenuItemsBuilder == null
          ? null
          : (tileContext, close) => widget.participantMenuItemsBuilder!(
              tileContext,
              participant,
              close,
            ),
      // A camera tile showing the avatar fallback has no feed to fill a screen with; a screen-share tile always does, since its key only exists while the share is up.
      onExpand: isScreen || participant.isCameraOn
          ? () => unawaited(_expand(key, participant, isScreen))
          : null,
      semanticLabel: isScreen
          ? (participant.isLocal
                ? "Your screen share, on this call's canvas"
                : "${participant.name}'s screen share, on this call's canvas")
          : '${participant.name}${participant.isLocal ? ', you' : ''}, '
                "on this call's canvas",
      // Real content moves to CanvasPresenceBackdrop when sent to back; .expand, not .shrink, or the wrapping GestureDetector's own opaque hit box shrinks with it.
      child: sentToBack
          ? const SizedBox.expand()
          // The pop plays once per tile mount (a participant arriving), never on pan or zoom, which only move the tile's slot.
          : CallTilePop(
              child: isScreen
                  ? CanvasScreenShareBubble(
                      participant: participant,
                      view: widget.screenShareViewFor(identity),
                    )
                  : CanvasPresenceBubble(
                      participant: participant,
                      cameraView: participant.isCameraOn
                          ? widget.cameraViewFor(identity)
                          : null,
                    ),
            ),
    );
  }
}
