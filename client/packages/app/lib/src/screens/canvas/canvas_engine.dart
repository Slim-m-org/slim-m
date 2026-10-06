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

import '../../providers/blocks_controller.dart';
import '../../providers/live_events.dart';
import '../../providers/providers.dart';
import '../../providers/sync_controller.dart';
import '../../providers/user_profiles.dart';
import 'canvas_activity_log.dart';
import 'canvas_commit_queue.dart';
import 'canvas_cursor_relay.dart';
import 'canvas_image_hydrator.dart';
import 'canvas_live_event_dispatch.dart';
import 'canvas_media_slot_sync.dart';
import 'canvas_ops_controller.dart';
import 'canvas_stroke_preview_relay.dart';
import 'canvas_sync.dart';

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
  });

  final bool loading;
  final String? error;
  final bool truncated;

  CanvasEngineState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    bool? truncated,
  }) => CanvasEngineState(
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    truncated: truncated ?? this.truncated,
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
      onHardReset: activityLog.recordResync,
    );
    // Registered once here, not in build: a listener re-attached per rebuild would fire a catch-up per rebuild, not per transition into live.
    _syncStatusSubscription = _ref.listen<SyncStatus>(syncControllerProvider, (
      previous,
      next,
    ) {
      if (next == SyncStatus.live) {
        unawaited(sync.catchUp());
        unawaited(slotSync.fetch());
      }
    });
    // No fetch here: CanvasSurface's first setViewport call reaches _onCameraMoved below and fetches the real region, not a wasted one against a zero viewport.
    document.addListener(_onCameraMoved);
    unawaited(slotSync.fetch());
  }

  final Ref _ref;
  final String channelId;

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
      CanvasPresenceTileOverrides();

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
    onError: reportError,
    onRemoveFailed: () {
      _fetched = null;
      return fetch(keepError: true);
    },
  );

  CanvasCursorRelay? _cursorRelay;
  CanvasCursorRelay get cursorRelay => _cursorRelay ??= CanvasCursorRelay(
    cursors: cursors,
    paletteSize: AppCanvasColors.cursors.length,
    send: (x, y) => _ref
        .read(syncControllerProvider.notifier)
        .notifyCanvasCursor(channelId, x, y),
    resolveLabel: _cursorLabel,
    isBlocked: (userId) => _ref.read(blocksProvider).contains(userId),
    selfId: () => _ref.read(meProvider).valueOrNull?.id,
  );

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
            ),
        isBlocked: (userId) => _ref.read(blocksProvider).contains(userId),
        selfId: () => _ref.read(meProvider).valueOrNull?.id,
      );

  /// [state.error]'s exact text for an almost-certainly-transient fetch
  /// failure - shared with `CanvasPane`'s `onRetryError` gate, so the one
  /// error this engine can meaningfully retry (re-running [fetch]) is
  /// identified by more than a string literal repeated in two places.
  static const genericLoadError = 'The canvas could not be loaded.';

  /// Sets or clears the sentence `CanvasPaneBody` shows for a failed fetch or
  /// a refused write. A null message clears it, the same as `_refresh(() =>
  /// _error = null)` used to.
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
    applyPlacedObject: _apply,
    forgetFetchedRegion: () => _fetched = null,
    activityLog: activityLog,
    mediaSlotSync: slotSync,
  );

  void _apply(api.CanvasObject object) {
    final input = canvasStrokeInputFrom(object);
    if (input == null) return;
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

  /// A pan re-reads once the camera has settled, never per frame.
  ///
  /// [CanvasDocument]'s listenable fires on any content change too - a fetch
  /// landing, a live frame, a locally drawn stroke - since [CanvasDocument]'s
  /// `refresh()` and a real camera move both end in the same
  /// `notifyListeners()`. Reading [_lastCameraView] is what tells those
  /// apart: a content-only notification reports the same world view as last
  /// examined, so it returns before touching [_fetched] at all. Without that
  /// guard a still-truncated region never becomes "covered", so every one of
  /// those content notifications re-read a null [_fetched] and rescheduled a
  /// fetch for the unmoved viewport - forever, since the answer stays
  /// truncated for the same reason each time.
  void _onCameraMoved() {
    final view = document.worldView;
    if (view == _lastCameraView) return;
    final isFirstView = _lastCameraView == null;
    _lastCameraView = view;
    final fetched = _fetched;
    if (fetched != null &&
        fetched.contains(view.topLeft) &&
        fetched.contains(view.bottomRight)) {
      // Inside what is already fetched, only a bitmap evicted off screen can be missing.
      _panDebounce?.cancel();
      _panDebounce = Timer(
        const Duration(milliseconds: 150),
        hydrator.hydrateVisible,
      );
      return;
    }
    _panDebounce?.cancel();
    if (isFirstView) {
      unawaited(fetch());
      return;
    }
    _panDebounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(fetch()),
    );
  }

  Rect _padded(Rect view) {
    final wide = view.inflate(view.width.clamp(1, 4000) / 2);
    return Rect.fromLTRB(
      wide.left.clamp(-worldLimit, worldLimit),
      wide.top.clamp(-worldLimit, worldLimit),
      wide.right.clamp(-worldLimit, worldLimit),
      wide.bottom.clamp(-worldLimit, worldLimit),
    );
  }

  /// [keepError] spares the message a failed action just reported, which a
  /// successful read would otherwise clear along with a load error.
  Future<void> fetch({bool keepError = false}) async {
    final region = _padded(document.worldView);
    if (region.width <= 0 || region.height <= 0) return;
    try {
      final page = await _client.canvasViewport(
        channelId,
        region: api.CanvasRect(
          minX: region.left,
          minY: region.top,
          maxX: region.right,
          maxY: region.bottom,
        ),
        limit: 2000,
      );
      if (!mounted) return;
      for (final object in page.objects) {
        final input = canvasStrokeInputFrom(object);
        if (input != null) {
          document.applyPlaced(input);
          hydrator.hydrate(object);
        }
      }
      // Set before refresh(), not after: refresh() reaches _onCameraMoved synchronously and must see this fetch's own answer, not the value from before it ran.
      state = state.copyWith(
        loading: false,
        clearError: !keepError,
        // A truncated page is not coverage: recording it would let the next pan skip what this read never returned.
        truncated: page.hasMore,
      );
      _fetched = page.hasMore ? null : region;
      document.refresh();
      sync.seedFromViewport(page.latestSeq);
      await sync.catchUp();
    } on api.ForbiddenException {
      if (mounted) {
        state = state.copyWith(
          loading: false,
          error: 'The canvas is not available in this channel.',
        );
      }
    } on api.ApiException {
      if (mounted) {
        state = state.copyWith(loading: false, error: genericLoadError);
      }
    }
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
    _panDebounce?.cancel();
    _queue?.close();
    unawaited(_live?.cancel());
    _syncStatusSubscription?.close();
    sync.dispose();
    document.removeListener(_onCameraMoved);
    document.dispose();
    _cursorRelay?.dispose();
    cursors.dispose();
    _strokePreviewRelay?.dispose();
    remoteDrafts.dispose();
    activityLog.dispose();
    tileOverrides.dispose();
    super.dispose();
  }
}

/// One instance per open canvas, torn down the instant nothing watches it -
/// see this file's own top-level doc for why that teardown is the point.
final canvasEngineProvider = StateNotifierProvider.autoDispose
    .family<CanvasEngine, CanvasEngineState, String>(
      (ref, channelId) => CanvasEngine(ref, channelId),
    );
