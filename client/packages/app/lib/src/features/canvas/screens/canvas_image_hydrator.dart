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
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../providers/rate_limit_retry.dart';
import '../../../widgets/bounded_image_decode.dart';

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

/// The longest side a bitmap may be decoded from; past it the image is refused
/// before any pixel is allocated, because a few hundred KB of PNG can declare
/// gigabytes.
const int maxHydratedSourcePixels = 40 * 1000 * 1000;

/// The decode sizes an image is held at. All but the last are the server's own
/// preview buckets, so a fetch at a tier is one cacheable preview; the last is
/// the original, decoded down to [maxHydratedImageSide].
const List<int> hydrationTiers = [320, 640, 1280, maxHydratedImageSide];

/// The smallest tier whose side covers [pixels] on screen.
int hydrationTierFor(double pixels) {
  for (final tier in hydrationTiers) {
    if (pixels <= tier) return tier;
  }
  return hydrationTiers.last;
}

/// Encoded bytes kept so a tier swap or a restore after eviction does not
/// download the same preview again.
const int hydratedByteCacheBytes = 24 * 1024 * 1024;

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
  final Queue<({String id, String attachmentId, int? tier})> _waiting = Queue();
  int _active = 0;
  final Queue<String> _lru = Queue<String>();
  final Map<String, int> _bytesById = <String, int>{};
  final Map<String, int> _tierById = <String, int>{};
  final LinkedHashMap<(String, int), Uint8List> _encoded = LinkedHashMap();
  int _encodedBytes = 0;
  int _decodedBytes = 0;
  bool _disposed = false;

  /// Device pixels per logical pixel, so a bitmap is sharp on a dense screen.
  double devicePixelRatio =
      ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1;

  /// The decoded bytes currently held and counted against the budget.
  int get decodedBytes => _decodedBytes;

  /// The tier [id]'s bitmap is held at, or null with none.
  int? tierOf(String id) => _tierById[id];

  /// Counts a bitmap this client decoded itself (a paste) against the budget,
  /// so it is evicted and swapped like a fetched one.
  void adopt(String id, ui.Image image) {
    if (_disposed) return;
    _remember(
      id,
      image,
      hydrationTierFor(math.max(image.width, image.height).toDouble()),
    );
  }

  /// Requests [object]'s bitmap if it names an image the document holds
  /// without one. A no-op for a stroke, an image with no attachment id, or
  /// one that already has its bitmap, failed, or is being fetched -
  /// idempotent by id, so calling this on every viewport page or catch-up op
  /// costs nothing once an image has actually landed.
  void hydrate(api.CanvasObject object) {
    if (_disposed || object.kind != 'image') return;
    final attachmentId = object.props['attachment'];
    if (attachmentId is! String) return;
    if (document.idsOutsideBoard.contains(object.id)) return;
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
    _swapTiers();
  }

  /// Re-fetches a held bitmap that is too coarse for how large it now draws.
  void _swapTiers() {
    for (final entry in document.visibleImagesHoldingBitmap) {
      final held = _tierById[entry.id];
      if (held == null || held >= hydrationTiers.last) continue;
      final wanted = _wantedTier(entry.id);
      if (wanted > held) _request(entry.id, entry.attachmentId, tier: wanted);
    }
  }

  /// The tier [id] draws at right now.
  int _wantedTier(String id) {
    final bounds = document.objectBounds(id);
    if (bounds == null) return hydrationTiers.first;
    final side = math.max(bounds.w, bounds.h) * document.camera.zoom;
    return hydrationTierFor(side * devicePixelRatio);
  }

  /// [tier] names a swap of a held bitmap; null fetches one that is missing.
  void _request(String id, String attachmentId, {int? tier}) {
    if (_pending.contains(id) || !_wantsBitmap(id, tier)) return;
    _pending.add(id);
    _waiting.add((id: id, attachmentId: attachmentId, tier: tier));
    _startWaiting();
  }

  bool _wantsBitmap(String id, int? tier) =>
      document.imageAwaitsBitmap(id) ||
      (tier != null && document.hasImageBitmap(id) && _tierById[id] != tier);

  void _startWaiting() {
    while (!_disposed &&
        _active < maxConcurrentImageFetches &&
        _waiting.isNotEmpty) {
      final next = _waiting.removeFirst();
      if (!_wantsBitmap(next.id, next.tier)) {
        _pending.remove(next.id);
        continue;
      }
      _active++;
      unawaited(
        _fetch(next.id, next.attachmentId, next.tier).whenComplete(() {
          _active--;
          _startWaiting();
        }),
      );
    }
  }

  Future<Uint8List> _bytesAt(String attachmentId, int tier) async {
    final key = (attachmentId, tier);
    final kept = _encoded.remove(key);
    if (kept != null) return _encoded[key] = kept;
    final fetched = await _fetchWithRetry(attachmentId, tier);
    _keepEncoded(key, fetched.bytes);
    return fetched.bytes;
  }

  void _keepEncoded((String, int) key, Uint8List bytes) {
    if (bytes.length > hydratedByteCacheBytes ~/ 4) return;
    _encoded[key] = bytes;
    _encodedBytes += bytes.length;
    while (_encodedBytes > hydratedByteCacheBytes && _encoded.isNotEmpty) {
      _encodedBytes -= _encoded.remove(_encoded.keys.first)!.length;
    }
  }

  Future<api.FetchedBytes> _fetchWithRetry(
    String attachmentId,
    int tier,
  ) async {
    var backoff = rateLimitFallbackWait;
    final previewWidth = tier < hydrationTiers.last ? tier : null;
    for (var attempt = 1; ; attempt++) {
      try {
        return await client.fetchAttachment(
          attachmentId,
          previewWidth: previewWidth,
        );
      } on api.ApiException catch (error) {
        final delay = _retryDelay(error, attempt, backoff);
        if (delay == null) rethrow;
        await wait(delay);
        backoff *= 2;
        if (_disposed) rethrow;
      }
    }
  }

  /// Null means give up and surface the error.
  Duration? _retryDelay(api.ApiException error, int attempt, Duration backoff) {
    if (!_isTransient(error) || attempt >= imageFetchAttempts) return null;
    final named = error is api.RateLimitedException ? error.retryAfter : null;
    if (named != null && named > rateLimitMaxWait) return null;
    return named ?? backoff;
  }

  static bool _isTransient(api.ApiException error) =>
      error is api.TransportException ||
      error is api.RateLimitedException ||
      error is api.UnavailableException ||
      error is api.ServerException;

  Future<void> _fetch(String id, String attachmentId, int? swapTo) async {
    try {
      final tier = swapTo ?? _wantedTier(id);
      final bytes = await _bytesAt(attachmentId, tier);
      final image = await decodeBoundedImage(
        bytes,
        maxSide: tier,
        maxSourcePixels: maxHydratedSourcePixels,
      );
      _pending.remove(id);
      if (_disposed || !_wantsBitmap(id, swapTo)) {
        image.dispose();
        return;
      }
      document.setImageBitmap(id, image);
      _remember(id, image, tier);
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.media, 'load a canvas image', error, stack);
      _pending.remove(id);
      if (!_disposed && !_isTransient(error)) document.markImageLoadFailed(id);
    } catch (error, stack) {
      api.reportFailure(api.LogTag.media, 'load a canvas image', error, stack);
      _pending.remove(id);
      if (!_disposed) document.markImageLoadFailed(id);
    }
  }

  void _remember(String id, ui.Image image, int tier) {
    _forget(id);
    final bytes = image.width * image.height * 4;
    _bytesById[id] = bytes;
    _tierById[id] = tier;
    _decodedBytes += bytes;
    _lru.add(id);
    _trim();
  }

  void _forget(String id) {
    _tierById.remove(id);
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
    _shrinkVisible(onScreen);
  }

  /// Visible bitmaps held finer than they draw are swapped for a coarser tier
  /// rather than evicted, so nothing on screen blanks to pay for the budget.
  void _shrinkVisible(Set<String> onScreen) {
    for (final id in _lru.toList()) {
      if (_decodedBytes <= maxDecodedBytes) return;
      final held = _tierById[id];
      if (held == null || !onScreen.contains(id)) continue;
      final wanted = _wantedTier(id);
      if (held <= wanted) continue;
      final attachmentId = document.attachmentIdOf(id);
      if (attachmentId != null) _request(id, attachmentId, tier: wanted);
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
