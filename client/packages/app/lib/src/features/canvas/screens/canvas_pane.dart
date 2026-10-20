// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Voice Canvas, as a mode of a channel rather than a route.
///
/// This widget is a thin consumer of [CanvasEngine] (`canvas_engine.dart`),
/// which owns the document, the fetch, the live-event subscription and every
/// per-channel helper - see that file's own doc for the fetch and lifecycle
/// contract. What is left here is genuinely widget-shaped: the tool strip's
/// own state, fullscreen, and wiring the engine's objects onto
/// `CanvasPaneBody`'s params.
///
/// The live subscription inside the engine is a plain `.listen` on the sync
/// controller's broadcast stream, never a `StreamProvider` a widget watches -
/// two shapes of that hang a widget test with a symptom indistinguishable from
/// a slow CI job, and both are already recorded in the project's knowledge
/// base.
///
/// Every refetch is a cold fetch of the padded viewport, and the `previous`
/// rectangle the endpoint offers is deliberately never sent. It is a single
/// rectangle, so a client tracking several fetched regions can only pass their
/// bounding box, which claims coverage of space it never fetched: everything
/// old in the gap is held back from that read and from every later one, and
/// nothing backfills it. Re-delivery costs a duplicate, which id dedupe makes
/// free, and that is the cheaper mistake by a distance.
library;

import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:slimm_api/api.dart' as api;
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../desktop/window_fullscreen_hold.dart';
import '../../../ids.dart';
import '../../../permissions.dart';
import '../../members/widgets/member_pane.dart' show memberPaneVisibleProvider;
import '../../../routing/breakpoints.dart';
import '../../members/providers/blocks_controller.dart';
import '../providers/canvas_self_presence.dart';
import '../widgets/canvas_clear_scope.dart' show CanvasScopedClear;
import '../widgets/canvas_note_editor.dart';
import '../widgets/canvas_note_spans.dart';
import '../../members/providers/member_presence.dart' show membersProvider;
import '../../channels/providers/channel_permissions.dart';
import '../../../providers/providers.dart';
import '../../voice/providers/fullscreen_video.dart';
import '../../voice/providers/video_interest_relay.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/widgets/participant_call_menu.dart';
import 'canvas_activity_log.dart';
import 'canvas_call_dock.dart';
import 'canvas_commit_queue.dart';
import 'canvas_cursor_relay.dart';
import 'canvas_object_preview_relay.dart';
import 'canvas_engine.dart';
import 'canvas_object_locks.dart';
import 'canvas_forbidden_message.dart';
import 'canvas_fullscreen.dart';
import 'canvas_image_paste.dart';
import 'canvas_media_slot_sync.dart';
import 'canvas_note_sheet.dart';
import 'canvas_ops_controller.dart';
import 'canvas_pane_body.dart';
import 'canvas_pen_style.dart';
import 'canvas_quick_placement.dart';
import 'canvas_stroke_preview_relay.dart';
import 'canvas_tool_model.dart';
import 'canvas_sync.dart';
import 'canvas_drag_pan.dart';

part 'canvas_pane_fullscreen.dart';
part 'canvas_pane_gestures.dart';
part 'canvas_pane_helpers.dart';
part 'canvas_pane_self_presence.dart';

/// The channel whose canvas is open, or null.
///
/// A provider rather than a route: joining a call opens voice and the canvas
/// as one screen (STRATEGY), and a separate navigation step is the alternative
/// that was rejected. The cost is stated rather than discovered: no URL, no
/// deep link, and no browser back to close it.
final canvasOpenProvider = StateProvider<String?>((ref) => null);

class CanvasPane extends ConsumerStatefulWidget {
  const CanvasPane({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<CanvasPane> createState() => _CanvasPaneState();
}

class _CanvasPaneState extends ConsumerState<CanvasPane> {
  int _localZ = provisionalLocalZIndex;
  late CanvasTool _tool;
  bool _toolInitialised = false;

  /// What [_tool] was before fullscreen disarmed it, so leaving fullscreen
  /// hands back the tool the person was actually using rather than the
  /// [CanvasTool.pan] the mode itself forced.
  CanvasTool? _toolBeforeFullscreen;

  /// Whether focusing a tile is what dropped the chrome, so ending the focus restores it.
  bool _fullscreenFromFocus = false;
  late final WindowFullscreenHold _windowHold;
  CanvasShapeKind _shapeKind = CanvasShapeKind.rectangle;

  /// The note whose in-place editor is open, if any.
  String? _editingNoteId;

  /// The last mouse click on a note, so a second one soon after is a double click.
  ({String id, DateTime at})? _lastNoteClick;
  CanvasPenStyle _pen = const CanvasPenStyle();
  final _dragPan = CanvasDragPan();
  CanvasImagePaste? _imagePasteHelper;
  CanvasQuickPlacement? _quickPlacementHelper;

  /// Captured once here rather than read fresh from `ref` on every access:
  /// `ref.read`/`ref.watch` both throw once this element is unmounting (see
  /// [dispose]'s own doc), so a handle taken while it is still safe to ask
  /// is the only way [dispose] can reach the engine at all. Bound to
  /// [widget.channelId] as of this exact call, matching every other
  /// per-channel field this pane ever bound eagerly at construction - a
  /// later `didUpdateWidget` with a different channel id was never a case
  /// this pane handled.
  late final CanvasEngine _engine = ref.read(
    canvasEngineProvider(widget.channelId).notifier,
  );

  /// Forces the engine into existence now, matching the ordering every
  /// prior version of this pane gave its own sync setup: before this
  /// widget's first `build()` mounts a `CanvasSurface` that expects the
  /// document to already have a listener. `build()`'s own `ref.watch` is
  /// what keeps the engine alive past this call - accessing [_engine] alone
  /// would not stop the very next scheduler pass from disposing an engine
  /// nothing is watching yet.
  @override
  void initState() {
    super.initState();
    // Built here: dispose cannot read ref, and releasing the window must still work then.
    _windowHold = WindowFullscreenHold(
      ref.read(fullscreenVideoActiveProvider.notifier),
    );
    _engine; // touching the late field is what forces its ref.read now
    // This pane is the only content mounted while it exists, so one listener for the whole mount is safe: nothing else here could hold it at the same time.
    _imagePaste.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_toolInitialised) return;
    _toolInitialised = true;
    _tool = _defaultTool;
    _disarmIfAlreadyFullscreen();
  }

  /// Disposes the engine directly, synchronously, rather than trusting
  /// `canvasEngineProvider`'s own `.autoDispose` scheduling to get there:
  /// that scheduling only runs on the next rebuild after the last listener
  /// goes, which is soon but not now, and the engine's cursor and
  /// stroke-preview relays each hold a real, periodic `Timer` for that long.
  /// A closed canvas is closed the instant this method returns, not a frame
  /// later - [CanvasEngine.dispose]'s own doc covers the double-call this
  /// makes safe once `.autoDispose` gets to it too.
  ///
  /// [_engine] is used here rather than `ref.read`: by the time `dispose()`
  /// runs, Flutter has already marked this element defunct (`Element.unmount`
  /// calls `super.unmount()`, which does that, before calling `state.dispose()`
  /// at all), and riverpod's `ref.read`/`ref.watch` both throw once that has
  /// happened - `_engine`'s own field is what makes this reachable without
  /// touching `ref` at all.
  @override
  void dispose() {
    _imagePasteHelper?.stop();
    _windowHold.release();
    _engine.dispose();
    super.dispose();
  }

  /// The same bridge [_refresh] is, for a caller that needs the raw
  /// boolean rather than a guarded `setState` - `mounted` itself is
  /// unreachable from `_CanvasPaneGestures` for the same reason [_refresh]
  /// exists at all.
  bool get _mounted => mounted;

  /// `setState` and `mounted` are `@protected` on `State`, so an extension
  /// method - `_CanvasPaneGestures`'s own, in a different file even though
  /// the same library - cannot call either directly; this bridges that gap
  /// from a plain method the analyzer sees as a real member of this class.
  void _refresh([VoidCallback? mutate]) {
    if (mounted) setState(mutate ?? () {});
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider).valueOrNull;
    // Per-channel, not deployment-wide: docs/decisions/0011-per-channel-permissions.md, site 5.
    final manageCanvas = ref
        .watch(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageCanvas);
    final selfPresence = ref.watch(canvasSelfPresenceProvider);
    final fullscreen = _fullscreen;
    // The one ref.watch keeping canvasEngineProvider alive; see its own doc.
    final engineState = ref.watch(canvasEngineProvider(widget.channelId));
    _engine.objectPreviewGlide = AppMotion.reduced(
      context,
      objectPreviewGlideDuration,
    );
    ref.listen(voiceFlagsProvider, _closeWhenCallEnds);
    final noteSpanStyle = _noteSpanStyle(context);
    final editingNote = _editingNoteId != null;
    return CanvasObjectLocksScope(
      locks: _engine.objectLocks,
      child: CallbackShortcuts(
        bindings: {
          // Only bound while there is something to escape from, so Escape keeps reaching whatever else would have handled it.
          if (editingNote)
            const SingleActivator(LogicalKeyboardKey.escape): _onNoteEditCancel
          else if (fullscreen)
            const SingleActivator(LogicalKeyboardKey.escape): _toggleFullscreen
          else if (_memberPaneDocked)
            const SingleActivator(LogicalKeyboardKey.escape): _closeMemberPane,
          // None of these while a note is being typed in: Backspace and Ctrl+Z belong to its field.
          if (!editingNote) ..._canvasEditShortcuts(),
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) => _onToolKey(
            event,
            canDraw: !canvasErrorBlocksDrawing(engineState.error),
            fullscreen: fullscreen,
          ),
          child: CanvasPaneBody(
            channelId: widget.channelId,
            onClose: _closeCanvas,
            fullscreen: fullscreen,
            onToggleFullscreen: _toggleFullscreen,
            focusedTileKey: _focusedTileKey,
            onFocusTile: _focusTile,
            tool: _tool,
            onToolChanged: _onToolChanged,
            canUndo: _ops.canUndo,
            onUndo: () => unawaited(_onUndo()),
            canRedo: _ops.canRedo,
            onRedo: () => unawaited(_onRedo()),
            canManage: manageCanvas,
            document: _document,
            onClear: _onClear,
            scopedClear: _scopedClear,
            onPasteImage: () => unawaited(_imagePaste.pasteFromButton()),
            onPasteImageAt: (world) => unawaited(_imagePaste.pasteAt(world)),
            onRecenter: _onRecenter,
            onBringIntoBoard: () => unawaited(_onBringIntoBoard()),
            error: engineState.error,
            onDismissError: () => _engine.reportError(null),
            onRetryError: engineState.error == CanvasEngine.genericLoadError
                ? () => unawaited(_engine.fetch())
                : null,
            truncated: engineState.truncated,
            loading: engineState.loading,
            onStroke: _onStroke,
            onErase: _onErase,
            onEraseEnd: () => unawaited(_onEraseEnd()),
            onSelectStart: _onSelectStart,
            onSelectDrag: _onSelectDrag,
            onSelectEnd: () => unawaited(_onSelectEnd()),
            onSelectTap: _onSelectTap,
            onEditNote: _onEditNote,
            noteSpans: (text, base) =>
                buildNoteSpans(text, base, noteSpanStyle),
            noteSpansRevision: noteSpanStyle.revision,
            noteEditor: _editingNoteId == null
                ? null
                : CanvasNoteEditor(
                    key: ValueKey(_editingNoteId),
                    document: _document,
                    objectId: _editingNoteId!,
                    onSave: (text) =>
                        unawaited(_onNoteEditSave(_editingNoteId!, text)),
                    onCancel: _onNoteEditCancel,
                  ),
            onNotePlace: (world) => unawaited(_onNotePlace(world)),
            onShapePlace: (world, size) =>
                unawaited(_onShapePlace(world, size)),
            shapeKind: _shapeKind,
            onShapeKindChanged: (kind) => setState(() => _shapeKind = kind),
            pen: _pen,
            onPenChanged: (pen) => setState(() => _pen = pen),
            onBringToFront: (id) => unawaited(_onBringToFront(id)),
            onSendToBack: (id) => unawaited(_onSendToBack(id)),
            onDeleteSelected: (id) => unawaited(_onDeleteSelected(id)),
            selfId: me?.id,
            viewRelay: _engine.viewRelay,
            cursors: _cursors,
            cursorColors: AppCanvasColors.cursors,
            onPointerMoved: _onPointerMoved,
            onPointerLeft: () => _relay.reportLocalPointerLeft(),
            remoteDrafts: _remoteDrafts,
            onDraftPoint: _strokePreview.reportLocalDraftPoint,
            onDraftEnded: _strokePreview.endLocalDraft,
            callParticipants: _callParticipants(),
            cameraViewFor: (identity) => ref
                .read(voiceControllerProvider.notifier)
                .cameraViewFor(identity, declaresInterest: false),
            screenShareViewFor: (identity) => ref
                .read(voiceControllerProvider.notifier)
                .screenShareViewFor(identity, declaresInterest: false),
            tileOverrides: _tileOverrides,
            onCommitTile: (key, rect) => unawaited(_slotSync.commit(key, rect)),
            onVideoInterest: ref.read(videoInterestRelayProvider).declare,
            activityLog: _activityLog,
            selfBubbleHidden: selfPresence.hidden,
            onToggleSelfBubbleHidden: _onToggleSelfBubbleHidden,
            callDock: callDockDataFor(
              ref.watch(voiceFlagsProvider),
              ref.read(voiceControllerProvider.notifier),
              widget.channelId,
            ),
            participantMenuItemsBuilder: (context, participant, close) =>
                participantCallMenuItems(
                  context,
                  ref,
                  participant: participant,
                  close: close,
                ),
          ),
        ),
      ),
    );
  }
}
