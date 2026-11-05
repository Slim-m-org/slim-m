// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One favorite in the picker grid: its preview, or a plain mark when it has
/// none to draw (a video) or has gone unavailable.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/animation_gate.dart';
import '../../../widgets/image_decode.dart';
import '../../messages/providers/attachment_preview_bytes.dart';
import '../providers/favorite_preview_bytes.dart';

class FavoriteTile extends ConsumerWidget {
  const FavoriteTile({
    super.key,
    required this.favorite,
    required this.busy,
    required this.selecting,
    required this.onTap,
  });

  final api.Favorite favorite;

  /// Some tile is being sent, so every tile is disabled.
  final bool busy;
  final bool selecting;
  final VoidCallback onTap;

  bool get _isVideo => favorite.contentType?.startsWith('video/') ?? false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final title = favorite.title.isEmpty ? 'favorite' : favorite.title;
    return Semantics(
      button: true,
      enabled: favorite.available,
      label: favorite.available ? 'Send: $title' : 'Unavailable: $title',
      child: InkWell(
        onTap: busy || !favorite.available ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: ColoredBox(
            color: tokens.surfaceBase,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _content(context, ref, tokens),
                if (selecting)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.surfaceBase.withValues(alpha: 0.65),
                    ),
                    child: const Center(
                      child: AppSpinner(size: AppSpinnerSize.md),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, AppTokens tokens) {
    if (!favorite.available) {
      return _mark(tokens, AppIcons.imageMissing, 'Unavailable');
    }
    if (_isVideo) return _mark(tokens, AppIcons.play, favorite.title);
    final preview = favorite.isGif
        ? ref.watch(favoritePreviewBytesProvider(favorite.id))
        : ref.watch(
            attachmentPreviewBytesProvider((
              id: favorite.attachmentId!,
              bucket: 320,
            )),
          );
    return switch (preview) {
      AsyncData(value: final Uint8List bytes) => AnimationGate(
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          cacheWidth: decodeEdge(context, 160),
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
      AsyncError() => _mark(tokens, AppIcons.imageMissing, 'Unavailable'),
      _ => const Center(child: AppSpinner(size: AppSpinnerSize.sm)),
    };
  }

  Widget _mark(AppTokens tokens, IconData icon, String label) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppSizes.icon20, color: tokens.textSecondary),
            const SizedBox(height: AppSpacing.s4),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
