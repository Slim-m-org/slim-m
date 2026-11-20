// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A link preview's proxied image, honoring the same preview-quality setting
/// [AttachmentView] applies to an inline attachment image.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/animation_gate.dart';
import '../../../widgets/image_decode.dart';
import '../providers/attachment_preview_quality.dart';
import '../providers/link_preview.dart';
import 'attachment_view.dart' show AttachmentView, kInlineImageMax;

class LinkPreviewThumbnail extends ConsumerWidget {
  const LinkPreviewThumbnail({
    super.key,
    required this.token,
    required this.url,
    this.bounds,
    this.radius = AppRadii.control,
    this.fill = false,
  });

  final String token;

  /// The link the preview is for, refetched once if [token] has gone stale.
  final String url;

  /// Draws the image as large as fits in this box at its own aspect ratio,
  /// never cropped, with a sunken square in its place until it decodes. Null
  /// fits it inside [kInlineImageMax], cropped to fill.
  final Size? bounds;

  final double radius;

  /// Cover-crops the image into whatever box the parent gives, a sunken fill
  /// until it decodes. A video's 4:3 thumbnail carries black bars that its
  /// 16:9 box crops away.
  final bool fill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A stale token (a server restart before signed tokens) answers 404; one fresh preview brings a fresh token.
    ref.listen(linkPreviewImageBytesProvider(token), (_, next) {
      if (next.hasValue &&
          next.value == null &&
          ref.read(refreshedStalePreviewsProvider).add(url)) {
        ref.invalidate(linkPreviewProvider(url));
      }
    });
    final previewScale = ref
        .watch(attachmentPreviewQualityControllerProvider)
        .decodeScale;
    final bytes = ref.watch(linkPreviewImageBytesProvider(token)).valueOrNull;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final box = bounds;
    if (fill) {
      return _CoverFill(
        bytes: bytes,
        radius: radius,
        decodeScale: previewScale,
      );
    }
    if (box != null) {
      final placeholder = _ArtPlaceholder(
        edge: box.shortestSide,
        radius: radius,
      );
      if (bytes == null) return placeholder;
      return ConstrainedBox(
        constraints: BoxConstraints.loose(box),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: AnimationGate(
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              cacheHeight: decodeEdge(context, box.height, scale: previewScale),
              frameBuilder: (context, child, frame, synchronous) =>
                  frame == null && !synchronous ? placeholder : child,
              errorBuilder: (context, error, stackTrace) => placeholder,
            ),
          ),
        ),
      );
    }
    if (bytes == null) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: kInlineImageMax,
          maxHeight: kInlineImageMax,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: AnimationGate(
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              cacheWidth: decodeEdge(
                context,
                kInlineImageMax,
                scale: previewScale,
              ),
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtPlaceholder extends StatelessWidget {
  const _ArtPlaceholder({required this.edge, required this.radius});

  final double edge;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox.square(
      dimension: edge,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

class _CoverFill extends StatelessWidget {
  const _CoverFill({
    required this.bytes,
    required this.radius,
    required this.decodeScale,
  });

  final Uint8List? bytes;
  final double radius;
  final double decodeScale;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final sunken = DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    final data = bytes;
    if (data == null) return sunken;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AnimationGate(
        child: Image.memory(
          data,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: decodeEdge(context, kInlineImageMax, scale: decodeScale),
          errorBuilder: (context, error, stackTrace) => sunken,
        ),
      ),
    );
  }
}
