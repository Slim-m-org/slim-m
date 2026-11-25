// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bitmaps of the custom emoji drawn inline in notes and text boxes.
///
/// A painter cannot lay out a widget, so each emoji a note names is decoded once here and handed to the spans as an image.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../../emoji/providers/emoji_catalog_provider.dart';

/// Pixels an emoji is decoded to: the most it is ever drawn at on a zoomed board.
const double canvasInlineEmojiDecodePx = 96;

class CanvasNoteEmojiImages extends Notifier<Map<String, ui.Image>> {
  final _requested = <String>{};
  bool _disposed = false;

  @override
  Map<String, ui.Image> build() {
    ref.onDispose(() {
      _disposed = true;
      for (final image in state.values) {
        image.dispose();
      }
    });
    return const {};
  }

  /// The bitmap of emoji [id], or null while it loads; the first ask starts the load.
  ui.Image? imageOf(String id) {
    final held = state[id];
    if (held == null && _requested.add(id)) scheduleMicrotask(() => _load(id));
    return held;
  }

  Future<void> _load(String id) async {
    try {
      final bytes = await ref.read(customEmojiImageProvider(id).future);
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: canvasInlineEmojiDecodePx.round(),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      state = {...state, id: frame.image};
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'An inline emoji on the board would not load; it shows a placeholder',
        error,
        stack,
      );
    }
  }
}

final canvasNoteEmojiImagesProvider =
    NotifierProvider<CanvasNoteEmojiImages, Map<String, ui.Image>>(
      CanvasNoteEmojiImages.new,
    );
