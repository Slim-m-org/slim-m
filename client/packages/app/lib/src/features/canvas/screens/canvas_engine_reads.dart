// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_engine.dart';

/// The region reads of [CanvasEngine]: one pass over the padded view, and the
/// background walk over the rest of the board once it lands.
extension CanvasEngineReads on CanvasEngine {
  /// Ends in the same turn it decides to, so a read asked for in between
  /// starts a pass of its own instead of joining one that is over.
  Future<void> _readUntilSettled(bool keepError) async {
    var keep = keepError;
    var staleReads = 0;
    while (mounted) {
      _readAgain = false;
      _readAgainKeepsError = true;
      final stale = await _readRegionOnce(keepError: keep);
      staleReads = stale ? staleReads + 1 : 0;
      if (staleReads >= maxStaleTileReads) {
        // Every answer arrived older than the document; try again after a pause rather than spin.
        _loadRetry.schedule(() {
          if (mounted) unawaited(fetch());
        });
        break;
      }
      if (!stale && !_readAgain) break;
      keep = _readAgainKeepsError && keepError;
    }
    _reading = null;
  }

  api.CanvasRect _wireRect(Rect region) => api.CanvasRect(
    minX: region.left,
    minY: region.top,
    maxX: region.right,
    maxY: region.bottom,
  );

  Future<api.CanvasViewport> _readRect(Rect region) =>
      _client.canvasViewport(channelId, region: _wireRect(region), limit: 2000);

  /// Returns whether the page was older than the document and must be read again.
  Future<bool> _readRegionOnce({required bool keepError}) async {
    final region = _padded(document.worldView);
    if (region.width <= 0 || region.height <= 0) return false;
    try {
      final page = await _readRect(region);
      if (!mounted) return false;
      _loadRetry.succeeded();
      final outcome = sync.applyViewport(
        page,
        region,
        onObject: hydrator.hydrate,
      );
      if (outcome == CanvasPageOutcome.stale) return true;
      // Set before refresh(), not after: refresh() reaches _onCameraMoved synchronously and must see this fetch's own answer, not the value from before it ran.
      _emit((s) => s.copyWith(loading: false, clearError: !keepError));
      // A truncated page is not coverage: recording it would let the next pan skip what this read never returned.
      _fetched = page.hasMore ? null : region;
      document.refresh();
      hydrator.hydrateVisible();
      if (!_boardPaged) unawaited(_pageBoard(page));
    } on api.ForbiddenException catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'load canvas contents', error, stack);
      if (mounted) {
        _emit(
          (s) => s.copyWith(loading: false, error: canvasUnavailableMessage),
        );
      }
    } on api.NotFoundException catch (error, stack) {
      // A deleted channel never comes back, so retrying only hammers the server.
      api.reportFailure(api.LogTag.ui, 'load canvas contents', error, stack);
      if (mounted) {
        _emit(
          (s) => s.copyWith(loading: false, error: canvasUnavailableMessage),
        );
      }
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'load canvas contents', error, stack);
      if (mounted) {
        _emit(
          (s) =>
              s.copyWith(loading: false, error: CanvasEngine.genericLoadError),
        );
        _loadRetry.schedule(() {
          if (mounted) unawaited(fetch());
        });
      }
    }
    return false;
  }

  /// The visible area is up; this brings in the rest, quietly, and says how far it is.
  Future<void> _pageBoard(api.CanvasViewport first) async {
    if (_paging) return;
    _paging = true;
    _boardPaged = true;
    const world = Rect.fromLTRB(
      -worldLimit,
      -worldLimit,
      worldLimit,
      worldLimit,
    );
    final seeds = CanvasBoardPager.seedsFor(canvasBoard, world);
    void progress(int? total) {
      if (mounted) {
        _emit(
          (s) => s.copyWith(
            paging: CanvasPaging(
              loaded: document.objectCount.value,
              total: total ?? first.totalObjects,
            ),
          ),
        );
      }
    }

    try {
      progress(first.totalObjects);
      final complete = await CanvasBoardPager(
        read: _readRect,
        apply: (page, tile) {
          final outcome = sync.applyViewport(
            page,
            tile,
            onObject: hydrator.hydrate,
          );
          document.refresh();
          return outcome;
        },
        onProgress: progress,
        isCancelled: () => !mounted,
      ).run(seeds);
      if (!mounted) return;
      if (complete) _fetched = world;
      _emit((s) => s.copyWith(truncated: !complete, clearPaging: true));
    } on api.ApiException catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'load the rest of the canvas',
        error,
        stack,
      );
      _boardPaged = false;
      if (mounted) _emit((s) => s.copyWith(clearPaging: true));
    } finally {
      _paging = false;
    }
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
}
