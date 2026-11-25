// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tiles of the phone composer's photo strip.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'photo_library.dart';

/// The widest a tile gets, so a phone shows three columns and a narrow one two.
const double photoStripMaxTileExtent = 140;

/// The sheet-style handle that says the panel can be swiped down.
class PhotoStripGrabHandle extends StatelessWidget {
  const PhotoStripGrabHandle({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 4,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class PhotoStripTile extends ConsumerStatefulWidget {
  const PhotoStripTile({
    super.key,
    required this.photo,
    required this.busy,
    required this.onTap,
  });
  final RecentPhoto photo;

  /// The original is being read: a spinner covers the tile.
  final bool busy;
  final VoidCallback onTap;

  @override
  ConsumerState<PhotoStripTile> createState() => _PhotoStripTileState();
}

class _PhotoStripTileState extends ConsumerState<PhotoStripTile> {
  late final Future<Uint8List?>? _thumb = ref
      .read(photoLibraryProvider)
      ?.thumbnail(widget.photo.id, (photoStripMaxTileExtent * 2).round());

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: widget.photo.isVideo ? 'Attach video' : 'Attach photo',
      child: GestureDetector(
        onTap: () {
          AppHaptics.selection();
          widget.onTap();
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<Uint8List?>(
                  future: _thumb,
                  builder: (context, snap) => snap.data == null
                      ? ColoredBox(color: tokens.surfaceRaised)
                      : Image.memory(snap.data!, fit: BoxFit.cover),
                ),
                if (widget.photo.isVideo)
                  Positioned(
                    left: AppSpacing.s4,
                    bottom: AppSpacing.s4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.surfaceSunken.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.s4),
                        child: Icon(
                          AppIcons.camera,
                          size: AppSizes.icon16,
                          color: tokens.textPrimary,
                        ),
                      ),
                    ),
                  ),
                if (widget.busy)
                  ColoredBox(
                    color: tokens.surfaceSunken.withValues(alpha: 0.6),
                    child: const Center(child: AppSpinner()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AllPhotosTile extends StatelessWidget {
  const AllPhotosTile({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: 'All photos',
      child: GestureDetector(
        onTap: () {
          AppHaptics.selection();
          onTap();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: SizedBox.expand(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  AppIcons.image,
                  size: AppSizes.icon24,
                  color: tokens.textSecondary,
                ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'All photos',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
