// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One channel's Voice Canvas sync, behind a provider rather than a
/// [State] field.
///
/// [CanvasEngine] owns exactly what used to live directly on
/// `_CanvasPaneState`: the document, the cursor and stroke-preview relays,
/// the media-slot sync, the activity log, the op stream reconciler and the
/// live-event subscription that feeds it. `CanvasPane` becomes a consumer
/// that reads this and wires it to widgets; it neither constructs nor tears
/// any of it down itself.
///
/// [canvasEngineProvider] is `.autoDispose.family`, keyed on channel id: one
/// instance per open canvas, torn down the instant nothing watches it any
/// more. That teardown is the whole point - without it, closing the canvas
/// would leave this still listening for live frames and still holding the
/// document's decoded bitmaps, for a pane nobody can see.
library;

import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../members/providers/blocks_controller.dart';
import '../providers/canvas_grid_snap.dart';
import '../providers/canvas_layout_store.dart';
import '../../../providers/app_lifecycle.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';
import '../../members/providers/user_profiles.dart';
import '../../voice/providers/voice_flags.dart';
import 'canvas_activity_log.dart';
import 'canvas_board_pager.dart';
import 'canvas_commit_queue.dart';
import 'canvas_cursor_relay.dart';
import 'canvas_forbidden_message.dart';
import 'canvas_image_hydrator.dart';
import 'canvas_live_event_dispatch.dart';
import 'canvas_load_retry.dart';
import 'canvas_media_slot_sync.dart';
import 'canvas_presence_geometry.dart'
    show presenceTileIdentity, presenceTileKind;
import 'canvas_object_locks.dart';
import 'canvas_object_preview_relay.dart';
import 'canvas_ops_controller.dart';
import 'canvas_personal_layout_keeper.dart';
import 'canvas_stroke_preview_relay.dart';
import 'canvas_view_follower.dart';
import 'canvas_view_relay.dart';
import 'canvas_sync.dart';

part 'canvas_engine_reads.dart';

/// [CanvasEngine.state]'s own shape: the three fields that used to be plain
/// `setState`-driven fields on `_CanvasPaneState` and still need to trigger a
/// rebuild when they change. Everything else the engine owns is a
/// `Listenable`/`ChangeNotifier` of its own, painted straight from
/// `CanvasPaneBody` without going through this at all.
class CanvasEngineState {
  const CanvasEngineState({
    this.loading = true,
    this.error,
    this.truncated = false,
    this.paging,
  });

  final bool loading;
  final String? error;
  final bool truncated;

  /// How much of the board has arrived while the rest is still being read, or
  /// null once the whole board is here.
  final CanvasPaging? paging;

  CanvasEngineState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    bool? truncated,
    CanvasPaging? paging,
    bool clearPaging = false,
  }) => CanvasEngineState(
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    truncated: truncated ?? this.truncated,
    paging: clearPaging ? null : (paging ?? this.paging),
  );
}

/// One channel's canvas: fetch, live sync, and every helper that reads or
/// writes its document.
///
/// Everything eager here (`document`, `cursors`, `remoteDrafts`,
/// `activityLog`, `tileOverrides`, `slotSync`, `hydrator`, `sync`) is built
/// in the constructor, exactly where `_CanvasPaneState.initState` used to
/// build it. Everything lazy (`commits`, `ops`, `cursorRelay`,
/// `strokePreviewRelay`) keeps the same `??=` shape it had as a
/// `_CanvasPaneState` field: a session that never draws, erases or moves a
/// pointer over this canvas never starts the relays' periodic prune timers.
class CanvasEngine extends StateNotifier<CanvasEngineState> {
  CanvasEngine(this._ref, this.channelId) : super(const CanvasEngineState()) {
    _live = _ref.read(liveEventsProvider).listen(_onEvent);
    sync = CanvasSync(
      channelId: channelId,
      client: _client,
      document: document,
      coldFetch: fetch,
      forgetFetchedRegion: () => _fetched = null,
      onObjectPlaced: hydrator.hydrate,
      onOpApplied: activityLog.recordOp,
      onHardReset: _onHardReset,
      settleObjectPreview: (id) => objectPreviewRelay.settle(id),
      isShownOffPlace: (id) =>
          document.elevatedObjectId.value == id ||
          (_objectPreviewRelay?.previews.holds(id) ?? false),
    );
    // Registered once here, not in build: a listener re-attached per rebuild would fire a catch-up per rebuild, not per transition into live.
    _syncStatusSubscription = _ref.listen<SyncStatus>(syncControllerProvider, (
      previous,
      next,
    ) {
      if (next == SyncStatus.live) {
        unawaited(sync.catchUp());
        _refetchIfLoadFailed();
        hydrator.hydrateVisible();
        if (!_boardPaged && !state.loading) unawaited(fetch(keepError: true));
        unawaited(slotSync.fetch());
        unawaited(objectLocks.fetch());
      }
    });
    // No fetch here: CanvasSurface's first setViewport call reaches _onCameraMoved below and fetches the real region, not a wasted one against a zero viewport.
    document.setBoard(canvasBoard, sharedArea: canvasSharedArea);
    document.addListener(_onCameraMoved);
    document.addListener(_follower.onViewMoved);
    viewMode.addListener(_follower.onViewModeChanged);
    _ref.listen<bool>(
      canvasGridSnapProvider,
      (_, snap) => document.snapToGrid.value = snap,
      fireImmediately: true,
    );
    unawaited(slotSync.fetch());
    unawaited(objectLocks.fetch());
    unawaited(_layoutKeeper.restore());
  }

  final Ref _ref;
  final String channelId;

  int _panes = 0;

  /// A pane for this channel started using the engine.
  void attachPane() => _panes++;

  /// A pane stopped using it; the last one out closes the engine at once rather
  /// than a frame later, because its relays hold periodic timers. A second pane
  /// still mounted (the page fade between two panes of one channel) keeps it.
  void detachPane() {
    if (_panes > 0) _panes--;
    if (_panes == 0) dispose();
  }

  late final api.SlimmApi _client = _ref.read(apiProvider);

  final CanvasDocument document = CanvasDocument();
  final CanvasCursors cursors = CanvasCursors();
  final RemoteStrokeDrafts remoteDrafts = RemoteStrokeDrafts();

  /// Every camera and screen-share tile's own drag, resize, lock and depth -
  /// shared and persistent, mirroring the server's own `canvas_media_slots`
  /// table (`slotSync`, below, is what keeps it current); only `hidden` stays
  /// local to this field. Lives for exactly this engine's own lifetime, so
  /// closing and reopening the canvas re-fetches rather than remembering -
  /// harmless, since the server is the real source of truth either way.
  final CanvasPresenceTileOverrides tileOverrides =
      CanvasPresenceTileOverrides()..board = canvasBoard;

  /// Whether this viewer is on the shared board or their own arrangement of it.
  late final CanvasViewMode viewMode = CanvasViewMode(
    document: document,
    tiles: tileOverrides,
  );

  late final CanvasPersonalLayoutKeeper _layoutKeeper =
      CanvasPersonalLayoutKeeper(
        channelId: channelId,
        mode: viewMode,
        store: openLayoutStore(_ref.read(canvasLayoutStoreProvider.future)),
        saveDelay: _ref.read(canvasPersonalLayoutSaveDelayProvider),
      );

  late final CanvasActivityLog activityLog = CanvasActivityLog(
    isBlocked: (userId) => _ref.read(blocksProvider).contains(userId),
  );

  /// Reads and writes [tileOverrides]' shared fields against the server -
  /// see that field's own doc for the split between what this syncs and
  /// what stays local.
  late final CanvasMediaSlotSync slotSync = CanvasMediaSlotSync(
    channelId: channelId,
    client: _client,
    overrides: tileOverrides,
    onError: reportError,
    sendPreview: (key, rect, {required ended}) =>
        _ref.read(syncControllerProvider.notifier).notifyCanvasMediaSlotPreview(
          channelId,
          presenceTileKind(key),
          presenceTileIdentity(key),
          (x: rect.left, y: rect.top, w: rect.width, h: rect.height),
          ended: ended,
        ),
    selfId: () => _ref.read(meProvider).valueOrNull?.id,
    isBlocked: (userId) => _ref.read(blocksProvider).contains(userId),
    timedOutUntil: () => _ref.read(meProvider).valueOrNull?.timedOutUntil,
  );

  /// Which objects are locked in place; see `CanvasObjectLocks`.
  late final CanvasObjectLocks objectLocks = CanvasObjectLocks(
    channelId: channelId,
    client: _client,
    onError: reportError,
  );

  late final CanvasImageHydrator hydrator = CanvasImageHydrator(
    client: _client,
    document: document,
  );

  late final CanvasSync sync;

  StreamSubscription<api.ServerEvent>? _live;
  ProviderSubscription<SyncStatus>? _syncStatusSubscription;
  Timer? _panDebounce;

  Rect? _fetched;

  /// The view [_onCameraMoved] last examined, regardless of what it decided
  /// to do about it. See that method's doc for why this exists.
  Rect? _lastCameraView;

  CanvasCommitQueue? _queue;
  CanvasCommitQueue get commits => _queue ??= CanvasCommitQueue(
    client: _client,
    channelId: channelId,
    onPlaced: _apply,
    onFailed: (id, message) {
      document
        ..kill(id)
        ..refresh();
      reportError(message);
    },
    onRemoved: (id) {
      document
        ..removeObject(id)
        // The removal's seq is unread; the cursor bounds it, and the feed replays it if a stale read lands first.
        ..confirmRemoved([id], sync.asOfSeq ?? 0)
        ..refresh();
      reportError('That stroke was erased while it was being saved.');
    },
    onEraseOnConfirm: (id) => unawaited(ops.eraseOnConfirm(id)),
    timedOutUntil: () => _ref.read(meProvider).valueOrNull?.timedOutUntil,
  );

  CanvasOpsController? _opsController;
  CanvasOpsController get ops => _opsController ??= CanvasOpsController(
    channelId: channelId,
    client: _client,
    document: document,
    commits: commits,
    onError: _reportRefusedWrite,
    onRemoveFailed: () {
      _fetched = null;
      return fetch(keepError: true);
    },
    isLocked: objectLocks.isLocked,
    onObjectPlaced: hydrator.hydrate,
  );

  CanvasCursorRelay? _cursorRelay;
  CanvasCursorRelay get cursorRelay => _cursorRelay ??= _buildCursorRelay();

  CanvasCursorRelay _buildCursorRelay() {
    // Read once: the relay says it left from dispose, when the container may no longer answer.
    final sync = _ref.read(syncControllerProvider.notifier);
    return CanvasCursorRelay(
      cursors: cursors,
      paletteSize: AppCanvasColors.cursors.length,
      send: (x, y) => sync.notifyCanvasCursor(channelId, x, y),
      sendLeft: (x, y) => sync.notifyCanvasCursor(channelId, x, y, left: true),
      resolveLabel: _cursorLabel,
      isBlocked: (userId) => _ref.read(blocksProvider).contains(userId),
      selfId: () => _ref.read(meProvider).valueOrNull?.id,
      canSend: _cursorHasAudience,
    );
  }

  CanvasViewRelay? _viewRelay;
  CanvasViewRelay get viewRelay => _viewRelay ??= CanvasViewRelay(
    board: canvasSharedArea,
    send: (view, {required summon}) =>
        _ref.read(syncControllerProvider.notifier).notifyCanvasView(channelId, (
          x: view.left,
          y: view.top,
          w: view.width,
          h: view.height,
        ), summon: summon),
    showView: _follower.showView,
    isBlocked: (userId) => _ref.read(blocksProvider).contains(userId),
    selfId: () => _ref.read(meProvider).valueOrNull?.id,
    canSend: _cursorHasAudience,
  );

  late final CanvasViewFollower _follower = CanvasViewFollower(
    document: document,
    viewMode: viewMode,
    relay: () => viewRelay,
    existingRelay: () => _viewRelay,
    glide: () => objectPreviewGlide,
  );

  bool _cursorHasAudience() {
    final inCallHere = _ref.read(voiceFlagsProvider).channelId == channelId;
    return shouldRelayCursor(
      focused: _ref.read(appFocusedProvider),
      inCallHere: inCallHere,
      othersInCall:
          inCallHere &&
          _ref.read(voiceParticipantsProvider).any((p) => !p.isLocal),
      remoteCursors: cursors.all.isNotEmpty,
    );
  }

  CanvasStrokePreviewRelay? _strokePreviewRelay;
  CanvasStrokePreviewRelay get strokePreviewRelay =>
      _strokePreviewRelay ??= CanvasStrokePreviewRelay(
        drafts: remoteDrafts,
        paletteSize: AppCanvasColors.cursors.length,
        send: (objectId, points, ended) => _ref
            .read(syncControllerProvider.notifier)
            .notifyCanvasStrokePreview(
              channelId,
              objectId,
              points,
              ended: ended,
              color: _strokePreviewRelay?.pen?.colorKey,
              width: _strokePreviewRelay?.pen?.width,
            ),
        isBlocked: (userId) => _ref.read(blocksProvider).contains(userId),
        selfId: () => _ref.read(meProvider).valueOrNull?.id,
      );

  CanvasObjectPreviewRelay? _objectPreviewRelay;
  CanvasObjectPreviewRelay get objectPreviewRelay =>
      _objectPreviewRelay ??= CanvasObjectPreviewRelay(
        previews: RemoteObjectPreviews(document),
        send: (objectId, box, ended) => _ref
            .read(syncControllerProvider.notifier)
            .notifyCanvasObjectPreview(channelId, objectId, box, ended: ended),
        isBlocked: (userId) => _ref.read(blocksProvider).contains(userId),
        selfId: () => _ref.read(meProvider).valueOrNull?.id,
        isDraggingLocally: (id) => document.elevatedObjectId.value == id,
        glide: () => objectPreviewGlide,
        onAbandoned: () {
          _fetched = null;
          unawaited(fetch(keepError: true));
        },
      );

  /// Set by the pane from the reduce-motion setting, which only the widget
  /// tree can read.
  Duration objectPreviewGlide = objectPreviewGlideDuration;

  /// [state.error]'s exact text for an almost-certainly-transient fetch
  /// failure - shared with `CanvasPane`'s `onRetryError` gate, so the one
  /// error this engine can meaningfully retry (re-running [fetch]) is
  /// identified by more than a string literal repeated in two places.
  static const genericLoadError = canvasLoadFailedMessage;

  void _emit(CanvasEngineState Function(CanvasEngineState current) change) {
    if (mounted) state = change(state);
  }

  /// A refused write leaves its optimistic local effect behind, and rolling
  /// that back to the box it started from can undo a newer remote move; the
  /// region read is the authority.
  void _reportRefusedWrite(String message) {
    reportError(message);
    _fetched = null;
    unawaited(fetch(keepError: true));
  }

  /// Sets or clears the sentence `CanvasPaneBody` shows for a failed fetch or
  /// a refused write; null clears it.
  void reportError(String? message) {
    if (!mounted) return;
    state = state.copyWith(error: message, clearError: message == null);
  }

  void _onEvent(api.ServerEvent event) => dispatchCanvasLiveEvent(
    event,
    paneChannelId: channelId,
    sync: sync,
    document: document,
    relay: () => cursorRelay,
    strokePreviewRelay: () => strokePreviewRelay,
    objectPreviewRelay: () => objectPreviewRelay,
    viewRelay: () => viewRelay,
    strokeDrafts: remoteDrafts,
    applyPlacedObject: _apply,
    forgetFetchedRegion: () => _fetched = null,
    activityLog: activityLog,
    mediaSlotSync: slotSync,
    objectLocks: objectLocks,
  );

  void _apply(api.CanvasObject object) {
    final input = canvasStrokeInputFrom(object);
    if (input == null) return;
    if (sync.clearedSincePlacement(object)) {
      document
        ..removeObject(object.id)
        ..refresh();
      return;
    }
    document
      ..applyPlaced(input)
      ..refresh();
    hydrator.hydrate(object);
  }

  /// A remote cursor's label as of the last resolved answer, kicking off a
  /// fetch for an id this session has not asked about yet - the same
  /// resolve-then-fall-back order `authorLabel` uses for a message author,
  /// minus the local `authorDisplayName` cache a cursor has no row to carry.
  ///
  /// Inlines what `resolveAuthorProfiles` does rather than calling it: that
  /// helper takes a `WidgetRef`, and this engine only ever holds the
  /// provider-side `Ref` riverpod hands a notifier's own `create`.
  String _cursorLabel(String userId) {
    final profiles = _ref.read(batchProfilesControllerProvider);
    unawaited(
      _ref.read(batchProfilesControllerProvider.notifier).resolve({userId}),
    );
    if (profiles.containsKey(userId)) {
      return profiles[userId]?.displayName ?? 'Deleted user';
    }
    return 'Someone';
  }

  void _onHardReset() {
    activityLog.recordResync();
    _objectPreviewRelay?.previews.clear();
    _boardPaged = false;
    _emit((s) => s.copyWith(loading: true));
  }

  /// Reads the padded view, then replays the feed from the cursor. Reads that
  /// overlap in time share one pass; [keepError] spares the message a failed
  /// action just reported, which a successful read would otherwise clear.
  Future<void> fetch({bool keepError = false}) async {
    await _readRegion(keepError: keepError);
    if (mounted) await sync.catchUp();
  }

  Completer<void>? _reading;
  bool _readAgain = false;
  bool _readAgainKeepsError = true;

  Future<void> _readRegion({required bool keepError}) {
    final running = _reading;
    if (running != null) {
      _readAgain = true;
      _readAgainKeepsError = _readAgainKeepsError && keepError;
      return running.future;
    }
    final done = _reading = Completer<void>();
    unawaited(_readRegionLoop(keepError).whenComplete(done.complete));
    return done.future;
  }

  Future<void> _readRegionLoop(bool keepError) async {
    try {
      await _readUntilSettled(keepError);
    } finally {
      _reading = null;
    }
  }

  bool _boardPaged = false;
  bool _paging = false;

  // A deploy or a rate limit fails the read for seconds; without this the view stays empty until the person pans or presses Retry.
  final _loadRetry = CanvasLoadRetry();

  void _refetchIfLoadFailed() {
    if (state.error != genericLoadError) return;
    _loadRetry.cancel();
    _fetched = null;
    unawaited(fetch());
  }

  /// Idempotent: `CanvasPane` calls this directly, synchronously, from its
  /// own `dispose()` (see that call site's own doc for why), and
  /// `canvasEngineProvider` - being `.autoDispose` - independently calls it
  /// again once it notices the last listener is gone. [StateNotifier]'s own
  /// `dispose()` asserts it is never called twice, so this guards on
  /// [mounted] rather than let that second, harmless call crash the first.
  @override
  void dispose() {
    if (!mounted) return;
    hydrator.dispose();
    _loadRetry.cancel();
    _panDebounce?.cancel();
    _follower.dispose();
    _queue?.close();
    _opsController?.dispose();
    unawaited(_live?.cancel());
    _syncStatusSubscription?.close();
    sync.dispose();
    document.removeListener(_onCameraMoved);
    document.removeListener(_follower.onViewMoved);
    viewMode.removeListener(_follower.onViewModeChanged);
    _viewRelay?.dispose();
    document.dispose();
    _cursorRelay?.dispose();
    cursors.dispose();
    _strokePreviewRelay?.dispose();
    _objectPreviewRelay?.dispose();
    remoteDrafts.dispose();
    activityLog.dispose();
    _layoutKeeper.dispose();
    viewMode.dispose();
    tileOverrides.dispose();
    objectLocks.dispose();
    slotSync.dispose();
    super.dispose();
  }
}

/// One instance per open canvas, torn down the instant nothing watches it -
/// see this file's own top-level doc for why that teardown is the point.
final canvasEngineProvider = StateNotifierProvider.autoDispose
    .family<CanvasEngine, CanvasEngineState, String>(
      (ref, channelId) => CanvasEngine(ref, channelId),
    );
