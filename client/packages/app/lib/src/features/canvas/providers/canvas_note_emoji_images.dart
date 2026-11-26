// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bitmaps of the custom emoji drawn inline in notes and text boxes.
///
/// A painter cannot lay out a widget, so each emoji a note names is decoded once here and handed to the spans as an image.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../../../providers/providers.dart' show serverUrlProvider;
import '../../emoji/providers/emoji_catalog_provider.dart';

/// Pixels an emoji is decoded to: the most it is ever drawn at on a zoomed board.
const double canvasInlineEmojiDecodePx = 96;

/// How many decoded emoji are kept; the least recently drawn one makes room for the next.
const int canvasInlineEmojiCacheLimit = 200;

/// The first wait before a failed load is tried again; each failure doubles it, up to [canvasInlineEmojiRetryCeiling].
const Duration canvasInlineEmojiRetryDelay = Duration(seconds: 5);
const Duration canvasInlineEmojiRetryCeiling = Duration(minutes: 5);

class CanvasNoteEmojiImages extends Notifier<Map<String, ui.Image>> {
  final _requested = <String>{};
  final _recent = <String>{};
  final _failures = <String, int>{};
  final _retries = <Timer>{};

  /// Counts the loads and evictions, so a painter can tell its images changed when the count of them did not.
  int revision = 0;

  /// What [state] holds, kept apart because reading [state] while disposing for a rebuild would rebuild again.
  Map<String, ui.Image> _held = const {};
  int _generation = 0;

  @override
  Map<String, ui.Image> build() {
    // Watched so an account on another server starts with none of this one's bitmaps.
    ref.watch(serverUrlProvider);
    final generation = ++_generation;
    _requested.clear();
    _recent.clear();
    _failures.clear();
    ref.onDispose(() {
      _generation = generation + 1;
      for (final timer in _retries) {
        timer.cancel();
      }
      _retries.clear();
      for (final image in _held.values) {
        image.dispose();
      }
      _held = const {};
    });
    return const {};
  }

  /// The bitmap of emoji [id], or null while it loads; the first ask starts the load.
  ui.Image? imageOf(String id) {
    final held = state[id];
    if (held != null) {
      _recent
        ..remove(id)
        ..add(id);
    } else if (_requested.add(id)) {
      scheduleMicrotask(() => _load(id));
    }
    return held;
  }

  Future<void> _load(String id) async {
    final generation = _generation;
    try {
      final bytes = await ref.read(customEmojiImageProvider(id).future);
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: canvasInlineEmojiDecodePx.round(),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (generation != _generation) {
        frame.image.dispose();
        return;
      }
      _failures.remove(id);
      _keep(id, frame.image);
    } on Object catch (error, stack) {
      if (generation != _generation) return;
      AppLog.swallowed(
        LogTag.media,
        'An inline emoji on the board would not load; it shows a placeholder and is tried again',
        error,
        stack,
      );
      _retryLater(id);
    }
  }

  void _keep(String id, ui.Image image) {
    final next = {...state, id: image};
    _recent
      ..remove(id)
      ..add(id);
    while (next.length > canvasInlineEmojiCacheLimit) {
      final oldest = _recent.firstWhere((held) => held != id);
      _recent.remove(oldest);
      _requested.remove(oldest);
      next.remove(oldest)?.dispose();
    }
    revision++;
    _held = next;
    state = next;
  }

  void _retryLater(String id) {
    final failures = _failures.update(id, (n) => n + 1, ifAbsent: () => 1);
    final wait =
        canvasInlineEmojiRetryDelay * (1 << (failures - 1).clamp(0, 6));
    late final Timer timer;
    timer = Timer(
      wait > canvasInlineEmojiRetryCeiling
          ? canvasInlineEmojiRetryCeiling
          : wait,
      () {
        _retries.remove(timer);
        unawaited(_load(id));
      },
    );
    _retries.add(timer);
  }
}

final canvasNoteEmojiImagesProvider =
    NotifierProvider<CanvasNoteEmojiImages, Map<String, ui.Image>>(
      CanvasNoteEmojiImages.new,
    );
