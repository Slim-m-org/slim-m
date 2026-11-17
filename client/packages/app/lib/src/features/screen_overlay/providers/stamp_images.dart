// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The baked pictures of the stamps in this call, in memory only (decision
/// 0121): never in the persistent image cache, and dropped when the call ends.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiAttachments;

import '../../../providers/bounded_image_decode.dart';
import '../../../providers/providers.dart';
import '../../emoji/providers/emoji_catalog_provider.dart';
import '../../voice/providers/voice_flags.dart';
import 'stamp_bake.dart';
import 'stamp_content.dart';

/// Baked pictures kept at once.
const stampImagesKept = 32;

/// The preview width a stamp's picture is fetched at.
const stampStillWidth = 640;

/// A picture that declares more pixels than this is refused before it is decoded.
const stampMaxSourcePixels = 40000000;

/// Original GIFs kept for tiles to animate, and the largest one that animates at all.
const _originalsKept = 4;
const stampAnimatedMaxBytes = 4 * 1024 * 1024;

/// The longest GIF canvas side that animates, since every frame decodes at the full canvas.
const stampAnimatedMaxSide = 1024;

/// Whether [bytes] are a GIF small enough for a tile to animate, its canvas read from the header
/// since a codec decodes every frame of an animation at the full canvas.
bool _gifAnimates(Uint8List bytes) {
  if (bytes.length > stampAnimatedMaxBytes || bytes.length < 10) return false;
  if (String.fromCharCodes(bytes, 0, 4) != 'GIF8') return false;
  final header = ByteData.sublistView(bytes, 6, 10);
  final width = header.getUint16(0, Endian.little);
  final height = header.getUint16(2, Endian.little);
  return math.max(width, height) <= stampAnimatedMaxSide;
}

class StampImageCache {
  StampImageCache({
    required Future<Uint8List> Function(String attachmentId) fetchStill,
    required Future<Uint8List> Function(String attachmentId) fetchOriginal,
    required Future<Uint8List> Function(String emojiId) customEmojiBytes,
    required Map<String, String> Function() customIndex,
  }) : _fetchStill = fetchStill,
       _fetchOriginal = fetchOriginal,
       _customEmojiBytes = customEmojiBytes,
       _customIndex = customIndex;

  final Future<Uint8List> Function(String) _fetchStill;
  final Future<Uint8List> Function(String) _fetchOriginal;
  final Future<Uint8List> Function(String) _customEmojiBytes;
  final Map<String, String> Function() _customIndex;

  // Insertion order is the use order: a hit moves to the end, the front is evicted.
  final _images = <String, ui.Image>{};
  final _loads = <String, Future<void>>{};
  final _originals = <String, Uint8List>{};
  final _originalLoads = <String, Future<Uint8List?>>{};
  var _generation = 0;

  /// Bumped by [dropGlyphs], so a standard emoji still baking then is not kept.
  var _glyphEpoch = 0;

  /// Where [content]'s picture is held, here and on the overlay runner.
  String keyOf(StampContent content) => content.imageKey(_customIndex());

  bool holds(StampContent content) => _images.containsKey(keyOf(content));

  /// Bakes [content] once, however many ask at the same time; throws when it cannot be had.
  Future<void> load(StampContent content) {
    final key = keyOf(content);
    final held = _images.remove(key);
    if (held != null) {
      _images[key] = held;
      return Future.value();
    }
    final inFlight = _loads[key];
    if (inFlight != null) return inFlight;
    final epoch = _glyphEpoch;
    late final Future<void> loading;
    void settle() {
      if (identical(_loads[key], loading)) _loads.remove(key);
    }

    loading = _bake(content, _generation).then(
      (image) {
        settle();
        if (key.startsWith('e:') && epoch != _glyphEpoch) {
          image.dispose();
          return;
        }
        _keep(key, image);
      },
      onError: (Object error, StackTrace stack) {
        settle();
        Error.throwWithStackTrace(error, stack);
      },
    );
    return _loads[key] = loading;
  }

  /// Bakes a picture from bytes already in hand, as for the viewer's own pick, so it is not fetched back.
  Future<void> seed(PictureStamp content, Uint8List bytes) async {
    final key = keyOf(content);
    if (_images.containsKey(key)) return;
    final generation = _generation;
    final image = await _bakeBytes(bytes);
    if (generation != _generation) {
      image.dispose();
      return;
    }
    _loads.removeWhere((held, _) => held == key);
    _keep(key, image, generation: generation);
  }

  /// [content]'s baked width over height, or null until it is loaded.
  double? aspectOf(StampContent content) {
    final image = _images[keyOf(content)];
    return image == null ? null : image.width / image.height;
  }

  /// A copy of [content]'s baked picture for the caller to paint and dispose, or null until it is loaded.
  ui.Image? peek(StampContent content) => _images[keyOf(content)]?.clone();

  /// [content]'s baked picture as a PNG for the overlay runner, loading it first.
  Future<Uint8List> png(StampContent content) async {
    await load(content);
    final image = peek(content);
    if (image == null) throw StateError('The stamp was dropped while loading.');
    try {
      return await encodeStampPng(image);
    } finally {
      image.dispose();
    }
  }

  /// The original GIF for a tile to animate, or null when it is too large to.
  Future<Uint8List?> original(String attachmentId) {
    final held = _originals.remove(attachmentId);
    if (held != null) return Future.value(_originals[attachmentId] = held);
    final generation = _generation;
    return _originalLoads[attachmentId] ??= _fetchOriginal(attachmentId)
        .then((bytes) {
          if (!_gifAnimates(bytes)) return null;
          if (generation == _generation) _keepOriginal(attachmentId, bytes);
          return bytes;
        })
        .whenComplete(() {
          _originalLoads.remove(attachmentId);
        });
  }

  /// Forgets the baked standard emoji, which a font that loaded late would draw differently.
  void dropGlyphs() {
    _glyphEpoch++;
    for (final key in [
      for (final key in {..._images.keys, ..._loads.keys})
        if (key.startsWith('e:')) key,
    ]) {
      _images.remove(key)?.dispose();
      _loads.remove(key);
    }
  }

  /// Drops everything, as when the call ends; a load still in flight is thrown away when it lands.
  void clear() {
    _generation++;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _loads.clear();
    _originals.clear();
    _originalLoads.clear();
  }

  Future<ui.Image> _bake(StampContent content, int generation) async {
    final image = switch (content) {
      EmojiStamp() => switch (content.customId(_customIndex())) {
        final id? => await _bakeBytes(await _customEmojiBytes(id)),
        null => await bakeEmojiGlyph(content.glyph),
      },
      PictureStamp(:final attachmentId) => await _bakeBytes(
        await _fetchStill(attachmentId),
      ),
    };
    if (generation != _generation) {
      image.dispose();
      throw StateError('The call ended while a stamp loaded.');
    }
    return image;
  }

  Future<ui.Image> _bakeBytes(Uint8List bytes) async {
    final decoded = await decodeBoundedImage(
      bytes,
      maxSide: stampBakeEdge,
      maxSourcePixels: stampMaxSourcePixels,
    );
    try {
      return await bakeScaled(decoded);
    } finally {
      decoded.dispose();
    }
  }

  void _keep(String key, ui.Image image, {int? generation}) {
    if (generation != null && generation != _generation) {
      image.dispose();
      return;
    }
    _images.remove(key)?.dispose();
    _images[key] = image;
    while (_images.length > stampImagesKept) {
      _images.remove(_images.keys.first)!.dispose();
    }
  }

  void _keepOriginal(String attachmentId, Uint8List bytes) {
    _originals[attachmentId] = bytes;
    while (_originals.length > _originalsKept) {
      _originals.remove(_originals.keys.first);
    }
  }
}

final stampImageCacheProvider = Provider<StampImageCache>((ref) {
  final api = ref.watch(apiProvider);
  final cache = StampImageCache(
    fetchStill: (id) async => (await api.fetchAttachment(
      id,
      previewWidth: stampStillWidth,
      firstFrame: true,
    )).bytes,
    fetchOriginal: (id) async => (await api.fetchAttachment(id)).bytes,
    customEmojiBytes: (id) => ref.read(customEmojiImageProvider(id).future),
    customIndex: () => ref.read(customEmojiIndexProvider),
  );
  ref.listen(voiceFlagsProvider.select((flags) => flags.channelId), (
    before,
    after,
  ) {
    if (before != after) cache.clear();
  });
  ref.onDispose(cache.clear);
  return cache;
});
