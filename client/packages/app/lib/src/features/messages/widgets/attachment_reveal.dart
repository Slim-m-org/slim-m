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
import 'message_row_parts.dart' show AttachmentPlaceholder;

/// The stand-in for a held preview: [icon] + [line] for one not yet downloaded,
/// or [preview] (a first frame) under a play badge for a held gif. One tap
/// calls [onReveal]. Captioned like the real preview, so a held row still reads
/// as a named file. [maxEdge] caps the frozen-frame box on both axes.
/// [showBadge] false hides the play badge while the preview is already
/// animating under a pointer, keeping the tile's layout as it was.
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
  });

  final String caption;
  final VoidCallback onReveal;
  final double maxEdge;
  final IconData? icon;
  final String? line;
  final Widget? preview;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final radius = BorderRadius.circular(AppRadii.control);

    final Widget body = preview != null
        ? ClipRRect(
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxEdge,
                maxHeight: maxEdge,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  preview!,
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
              const SizedBox(height: AppSpacing.s4),
              Text(
                caption,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
class AttachmentFirstFrame extends StatefulWidget {
  const AttachmentFirstFrame({
    super.key,
    required this.bytes,
    required this.cacheWidth,
  });

  final Uint8List bytes;
  final int cacheWidth;

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
      final codec = await ui.instantiateImageCodec(
        widget.bytes,
        targetWidth: widget.cacheWidth,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _frame = frame.image);
    } catch (_) {
      // A frame that will not decode leaves the neutral box; the tap reveals.
    }
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
    return RawImage(image: frame, fit: BoxFit.contain);
  }
}
