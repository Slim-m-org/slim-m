// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fetches and decodes the bitmap for a placed image object arriving from
/// anywhere other than this client's own paste: the initial viewport fetch,
/// catch-up ops, and a live event from another participant.
///
/// [CanvasImagePaste] hands its own just-decoded bitmap straight to
/// [CanvasDocument.setImageBitmap], so pasting an image is instant. Every
/// other arrival only ever carried an attachment id - `props.attachment` on
/// the wire - and nothing fetched the bytes back, which meant an image was
/// visible only to the client that pasted it, only for the life of that
/// pane. This is the fix: a plain-Dart hydrator, the same shape as
/// `CanvasSync` and `CanvasOpsController`, that `CanvasPane` calls
/// unconditionally on every real placement and lets decide for itself
/// whether there is anything to fetch.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../providers/rate_limit_retry.dart';
import '../../widgets/bounded_image_decode.dart';

/// A crude bound on total decoded pixel bytes, not a byte-accurate cache.
///
/// The roadmap names a bounded LRU (96 MB iOS, 256 MB Linux) for exactly
/// this reason; this is deliberately not that. One platform-uniform figure,
/// well under even the tighter iOS one, bounds every platform the same way
/// rather than branching on `Platform.isIOS` for a first pass, at the cost
/// of evicting more eagerly than a desktop could actually afford.
const int defaultMaxDecodedImageBytes = 64 * 1024 * 1024;

/// The longer side a retained bitmap is decoded to at most.
///
/// Decoding a 12 megapixel photo at full size costs 48 MB for a box that is
/// a few hundred world units wide, so two of them blew the whole budget.
const int maxHydratedImageSide = 2048;

/// How many attachment fetches run at once; the rest wait their turn, so a
/// canvas of hundreds of images cannot spend the shared asset rate budget in
/// one burst.
const int maxConcurrentImageFetches = 6;

/// Tries per image before a transient error is left for the next viewport
/// settle to retry.
const int imageFetchAttempts = 3;

/// Hydrates a placed [api.CanvasObject]'s bitmap, bounded and safe to call
/// repeatedly for the same id.
///
/// **The document decides what still needs a bitmap**, not this class: a
/// removal frees the bitmap, a restore or a hard reset puts back a brand new
/// stroke, and a remembered "already hydrated" id went stale across all
/// three. A live image with no bitmap and no failed load is the only thing
/// ever fetched.
///
/// **Eviction spares what is on screen.** Past the budget the oldest bitmap
/// that is off screen goes first; if everything left is on screen it is all
/// kept, since evicting a visible image only blanks it until the next fetch
/// evicts another. [hydrateVisible] brings back an image evicted while it was
/// off screen once the view reaches it.
///
/// **A refusal is not retried.** A 403 or 404 is a legitimate, stable answer -
/// the object's channel access changed, or the attachment was swept as an
/// orphan - not worth hammering the attachment store over. It is remembered
/// on the stroke itself, so a restored object, which is a new stroke, gets one
/// fresh try. A transient error (429, 5xx, a dropped connection) is retried
/// with backoff and, once the tries run out, left unmarked so the next
/// [hydrateVisible] tries again rather than the image showing as broken.
class CanvasImageHydrator {
  CanvasImageHydrator({
    required this.client,
    required this.document,
    this.maxDecodedBytes = defaultMaxDecodedImageBytes,
    this.wait = sleepFor,
  });

  final api.SlimmApi client;
  final CanvasDocument document;
  final int maxDecodedBytes;
  final RateLimitWait wait;

  final Set<String> _pending = <String>{};
  final Queue<({String id, String attachmentId})> _waiting = Queue();
  int _active = 0;
  final Queue<String> _lru = Queue<String>();
  final Map<String, int> _bytesById = <String, int>{};
  int _decodedBytes = 0;
  bool _disposed = false;

  /// Requests [object]'s bitmap if it names an image the document holds
  /// without one. A no-op for a stroke, an image with no attachment id, or
  /// one that already has its bitmap, failed, or is being fetched -
  /// idempotent by id, so calling this on every viewport page or catch-up op
  /// costs nothing once an image has actually landed.
  void hydrate(api.CanvasObject object) {
    if (_disposed || object.kind != 'image') return;
    final attachmentId = object.props['attachment'];
    if (attachmentId is! String) return;
    _request(object.id, attachmentId);
  }

  /// Requests the bitmap of every image on screen that has none, which is
  /// how an image evicted while off screen comes back when the view reaches
  /// it without a refetch of the region.
  void hydrateVisible() {
    if (_disposed) return;
    for (final image in document.visibleImagesAwaitingBitmap) {
      _request(image.id, image.attachmentId);
    }
  }

  void _request(String id, String attachmentId) {
    if (_pending.contains(id) || !document.imageAwaitsBitmap(id)) return;
    _pending.add(id);
    _waiting.add((id: id, attachmentId: attachmentId));
    _startWaiting();
  }

  void _startWaiting() {
    while (!_disposed &&
        _active < maxConcurrentImageFetches &&
        _waiting.isNotEmpty) {
      final next = _waiting.removeFirst();
      if (!document.imageAwaitsBitmap(next.id)) {
        _pending.remove(next.id);
        continue;
      }
      _active++;
      unawaited(
        _fetch(next.id, next.attachmentId).whenComplete(() {
          _active--;
          _startWaiting();
        }),
      );
    }
  }

  Future<api.FetchedBytes> _fetchWithRetry(String attachmentId) async {
    var backoff = rateLimitFallbackWait;
    for (var attempt = 1; ; attempt++) {
      try {
        return await client.fetchAttachment(attachmentId);
      } on api.ApiException catch (error) {
        if (!_isTransient(error) || attempt >= imageFetchAttempts) rethrow;
        final named = error is api.RateLimitedException
            ? error.retryAfter
            : null;
        if (named != null && named > rateLimitMaxWait) rethrow;
        await wait(named ?? backoff);
        backoff *= 2;
        if (_disposed) rethrow;
      }
    }
  }

  static bool _isTransient(api.ApiException error) =>
      error is api.TransportException ||
      error is api.RateLimitedException ||
      error is api.UnavailableException ||
      error is api.ServerException;

  Future<void> _fetch(String id, String attachmentId) async {
    try {
      final fetched = await _fetchWithRetry(attachmentId);
      final image = await decodeBoundedImage(
        fetched.bytes,
        maxSide: maxHydratedImageSide,
      );
      _pending.remove(id);
      if (_disposed || !document.imageAwaitsBitmap(id)) {
        image.dispose();
        return;
      }
      document.setImageBitmap(id, image);
      _remember(id, image);
    } on api.ApiException catch (error) {
      _pending.remove(id);
      if (!_disposed && !_isTransient(error)) document.markImageLoadFailed(id);
    } catch (_) {
      _pending.remove(id);
      if (!_disposed) document.markImageLoadFailed(id);
    }
  }

  void _remember(String id, ui.Image image) {
    _forget(id);
    final bytes = image.width * image.height * 4;
    _bytesById[id] = bytes;
    _decodedBytes += bytes;
    _lru.add(id);
    _trim();
  }

  void _forget(String id) {
    final bytes = _bytesById.remove(id);
    if (bytes == null) return;
    _decodedBytes -= bytes;
    _lru.remove(id);
  }

  void _trim() {
    _lru.where((id) => !document.hasImageBitmap(id)).toList().forEach(_forget);
    if (_decodedBytes <= maxDecodedBytes) return;
    final onScreen = document.visibleIds;
    for (final id in _lru.toList()) {
      if (_decodedBytes <= maxDecodedBytes) return;
      if (onScreen.contains(id)) continue;
      _forget(id);
      document.evictImageBitmap(id);
    }
  }

  /// Marks every in-flight fetch's eventual answer as one to discard rather
  /// than apply to [document], which may itself be disposed by the time a
  /// pending [_fetch] completes, and drops the queue of fetches not started.
  void dispose() {
    _disposed = true;
    _waiting.clear();
  }
}
