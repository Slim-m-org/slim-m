// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tappable stand-ins for an inline attachment held behind a performance
/// gate: a not-yet-downloaded image, or a gif frozen on its first frame under a
/// play badge. One tap reveals it. Split out of `attachment_view.dart` to keep
/// that file within its size budget.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/modal_page.dart' show kScrimColor;
import 'cover_resize_image.dart';
import 'message_row_parts.dart' show AttachmentPlaceholder;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The stand-in for a held preview: [icon] + [line] for one not yet downloaded,
/// or [preview] (a first frame) under a play badge for a held gif. One tap
/// calls [onReveal]. Captioned like the real preview, so a held row still reads
/// as a named file. [maxEdge] caps the frozen-frame box on both axes.
/// [showBadge] false hides the play badge while the preview is already
/// animating under a pointer, keeping the tile's layout as it was.
/// [tileEdge] is a gallery tile's: the preview fills it uncaptioned, as the
/// revealed tile does, so a tap does not resize it.
class AttachmentRevealTile extends StatelessWidget {
  const AttachmentRevealTile({
    super.key,
    required this.caption,
    required this.onReveal,
    required this.maxEdge,
    this.icon,
    this.line,
    this.preview,
    this.showBadge = true,
    this.tileEdge,
  });

  final String caption;
  final VoidCallback onReveal;
  final double maxEdge;
  final IconData? icon;
  final String? line;
  final Widget? preview;
  final bool showBadge;
  final double? tileEdge;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final radius = BorderRadius.circular(AppRadii.control);
    final tile = tileEdge;

    final Widget body = preview != null
        ? ClipRRect(
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: tile == null
                  ? BoxConstraints(maxWidth: maxEdge, maxHeight: maxEdge)
                  : attachmentTileBox(tile),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (tile == null)
                    preview!
                  else
                    Positioned.fill(child: preview!),
                  // Hidden, not removed: the badge may be what sizes this stack.
                  Visibility(
                    visible: showBadge,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: const _PlayBadge(),
                  ),
                ],
              ),
            ),
          )
        : Container(
            width: 260,
            height: 120,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.stripe,
              borderRadius: radius,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: AppSizes.icon28, color: tokens.textSecondary),
                const SizedBox(height: AppSpacing.s8),
                Text(
                  line ?? 'Tap to load',
                  style: AppText.ui.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          );

    return Semantics(
      button: true,
      label: line ?? 'Play $caption',
      onTap: onReveal,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onReveal,
          child: SelectionContainer.disabled(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: tokens.borderSubtle),
                    borderRadius: radius,
                  ),
                  child: body,
                ),
                if (tile == null) ...[
                  const SizedBox(height: AppSpacing.s4),
                  Text(
                    caption,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A gallery tile's picture: the tile less the 1px border around it.
BoxConstraints attachmentTileBox(double tile) =>
    BoxConstraints.tight(Size.square(tile - 2));

/// The play glyph centred over a held gif's first frame.
class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  /// Opaque white regardless of theme: this sits on an arbitrary decoded
  /// frame, not a themed surface, so it cannot be one of [AppTokens]'
  /// contrast-tuned pairs the way chrome on a surface can.
  static const _glyphOnDark = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s12),
      decoration: const BoxDecoration(
        color: kScrimColor,
        shape: BoxShape.circle,
      ),
      child: const Icon(
        AppIcons.play,
        size: AppSizes.icon28,
        color: _glyphOnDark,
      ),
    );
  }
}

/// A gif's first frame, decoded once and shown still, so autoplay-off shows
/// what the gif is without animating (and re-decoding every frame) until asked.
/// Decoded and fitted as the moving copy is, so swapping one for the other never resizes it.
class AttachmentFirstFrame extends StatefulWidget {
  const AttachmentFirstFrame({
    super.key,
    required this.bytes,
    required this.cacheWidth,
    this.fit = BoxFit.contain,
  });

  final Uint8List bytes;

  /// The widest it decodes to, or the shorter side under a cover fit; a smaller gif keeps its own size.
  final int cacheWidth;

  /// Cover in a gallery tile, as the revealed tile's image is.
  final BoxFit fit;

  @override
  State<AttachmentFirstFrame> createState() => _AttachmentFirstFrameState();
}

class _AttachmentFirstFrameState extends State<AttachmentFirstFrame> {
  ui.Image? _frame;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(widget.bytes),
        getTargetSize: _noUpscale,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _frame = frame.image);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'An image preview could not be decoded; showing a placeholder',
        error,
        stack,
      );
    }
  }

  /// Shrinks to [AttachmentFirstFrame.cacheWidth] but never stretches, as
  /// `Image.memory`'s `cacheWidth` does, so the frame is the size it plays at.
  ui.TargetImageSize _noUpscale(int width, int height) {
    if (widget.fit == BoxFit.cover) {
      return coverTargetSize(width, height, widget.cacheWidth) ??
          ui.TargetImageSize(width: width, height: height);
    }
    return width > widget.cacheWidth
        ? ui.TargetImageSize(width: widget.cacheWidth)
        : ui.TargetImageSize(width: width, height: height);
  }

  @override
  void dispose() {
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    // Null (failed or still decoding): a neutral box keeps the badge tappable.
    if (frame == null) return const AttachmentPlaceholder();
    return RawImage(image: frame, fit: widget.fit);
  }
}
