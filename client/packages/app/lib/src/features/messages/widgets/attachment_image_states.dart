// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What an inline image shows before and instead of its pixels: a sized box
/// that says an image is coming, and one that says it did not, with a retry.
/// Split out of `attachment_view.dart` to keep that file within its budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/sync_controller.dart';

/// The height a lone image's stand-in takes, where the attachment carries no
/// dimensions to size it from.
const double kImagePlaceholderHeight = 200;

/// The sized box shared by both states. A lone image is as wide as it can be
/// drawn, a gallery tile is its square, so nothing shifts when pixels arrive.
class _ImageStateBox extends StatelessWidget {
  const _ImageStateBox({
    required this.width,
    required this.tileEdge,
    required this.icon,
    required this.filename,
    required this.children,
  });

  final double width;
  final double? tileEdge;
  final IconData icon;
  final String filename;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final tile = tileEdge;
    return Container(
      width: tile ?? width,
      height: tile ?? kImagePlaceholderHeight,
      padding: const EdgeInsets.all(AppSpacing.s8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      // A tile in a narrow column can be smaller than its content.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppSizes.icon28, color: tokens.textSecondary),
            const SizedBox(height: AppSpacing.s8),
            ...children,
            if (tile != null) ...[
              const SizedBox(height: AppSpacing.s4),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: tile - AppSpacing.s16),
                child: Text(
                  filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An image on its way. Announced as loading so it is not silent to a reader
/// that cannot see the box.
class AttachmentLoadingBox extends StatelessWidget {
  const AttachmentLoadingBox({
    super.key,
    required this.filename,
    required this.width,
    this.tileEdge,
  });

  final String filename;

  /// How wide a lone image's stand-in is drawn; ignored for a [tileEdge] tile.
  final double width;
  final double? tileEdge;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      label: 'Loading $filename',
      container: true,
      excludeSemantics: true,
      child: _ImageStateBox(
        width: width,
        tileEdge: tileEdge,
        icon: AppIcons.image,
        filename: filename,
        children: [
          Text(
            'Loading',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// An image that did not arrive. [onRetry] refetches; it also fires by itself
/// when the live connection comes back, since a dropped link is what usually
/// left this here.
class AttachmentFailureBox extends ConsumerWidget {
  const AttachmentFailureBox({
    super.key,
    required this.filename,
    required this.onRetry,
    required this.width,
    this.tileEdge,
    this.message = 'Could not load',
  });

  final String filename;
  final VoidCallback onRetry;
  final double width;
  final double? tileEdge;
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<SyncStatus>(syncControllerProvider, (previous, next) {
      if (next == SyncStatus.live && previous != SyncStatus.live) onRetry();
    });
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return _ImageStateBox(
      width: width,
      tileEdge: tileEdge,
      icon: AppIcons.imageMissing,
      filename: filename,
      children: [
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppText.ui.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s8),
        AppButton(
          label: 'Retry',
          icon: AppIcons.retry,
          size: AppButtonSize.sm,
          semanticLabel: 'Retry loading $filename',
          onPressed: onRetry,
        ),
      ],
    );
  }
}
