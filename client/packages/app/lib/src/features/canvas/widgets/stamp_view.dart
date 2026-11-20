// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One stamp drawn from its baked bitmap (decision 0121), the same one the
/// board and the overlay draw, so a stamp looks the same everywhere.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../../screen_overlay/providers/stamp_content.dart';
import '../../screen_overlay/providers/stamp_images.dart';

/// [content] fitted into its box; nothing until its bitmap is in. An animated
/// GIF, a picture or a custom emoji, plays from its original unless the
/// system asks for reduced motion.
class StampView extends ConsumerStatefulWidget {
  const StampView({super.key, required this.content, this.semanticLabel});

  final StampContent content;
  final String? semanticLabel;

  @override
  ConsumerState<StampView> createState() => _StampViewState();
}

class _StampViewState extends ConsumerState<StampView> {
  ui.Image? _image;
  Uint8List? _original;

  @override
  void initState() {
    super.initState();
    _take();
  }

  @override
  void didUpdateWidget(StampView old) {
    super.didUpdateWidget(old);
    if (old.content == widget.content) return;
    _image?.dispose();
    _image = null;
    _original = null;
    _take();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _take() async {
    final content = widget.content;
    final cache = ref.read(stampImageCacheProvider);
    var image = cache.peek(content);
    if (image == null) {
      try {
        await cache.load(content);
      } on Object catch (error, stack) {
        AppLog.swallowed(
          LogTag.media,
          'A stamp picture would not load; the stamp shows nothing',
          error,
          stack,
        );
        return;
      }
      image = cache.peek(content);
    }
    if (!mounted || content != widget.content) {
      image?.dispose();
      return;
    }
    setState(() => _image = image);
    final Uint8List? bytes;
    try {
      bytes = await cache.animation(content);
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'A stamp would not animate; it shows its still frame',
        error,
        stack,
      );
      return;
    }
    if (bytes != null && mounted && content == widget.content) {
      setState(() => _original = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final original = _original;
    final Widget picture;
    if (original != null && !MediaQuery.disableAnimationsOf(context)) {
      picture = Image.memory(
        original,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      );
    } else {
      picture = RawImage(
        image: _image,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    }
    final label = widget.semanticLabel;
    if (label == null) return ExcludeSemantics(child: picture);
    return Semantics(label: label, image: true, child: picture);
  }
}
