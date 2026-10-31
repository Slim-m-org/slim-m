// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The space's icon as a small rounded square, fetched with the session.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import 'image_decode.dart';

/// Keyed by when the icon was set, so a replacement is fetched afresh.
final spaceIconBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, int>(
      (ref, updatedAt) async =>
          (await ref.watch(apiProvider).fetchSpaceIcon()).bytes,
    );

/// Draws nothing when [updatedAt] is null, so a space with no icon looks as it
/// did before icons existed.
class SpaceIcon extends ConsumerWidget {
  const SpaceIcon({super.key, required this.updatedAt, required this.size});

  final int? updatedAt;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final at = updatedAt;
    if (at == null) return const SizedBox.shrink();
    final bytes = ref.watch(spaceIconBytesProvider(at)).valueOrNull;
    final edge = decodeEdge(context, size, minRatio: 2, oversample: 3);
    return SpaceIconFrame(
      size: size,
      child: bytes == null
          ? null
          : AppShapedImage(
              // Decoded near the painted size, as an avatar is; drawn straight from the source it aliased on a scaled desktop.
              image: ResizeImage(
                MemoryImage(bytes),
                width: edge,
                height: edge,
                policy: ResizeImagePolicy.fit,
              ),
              size: size,
              radius: AppRadii.control,
              errorBuilder: (_) => SpaceIconFrame(size: size),
            ),
    );
  }
}

/// The rounded square every icon surface shares; a null [child] draws the
/// sunken placeholder while the bytes load or fail. A child shapes itself
/// (see AppShapedImage): a clip here would not be anti-aliased on desktop GL.
class SpaceIconFrame extends StatelessWidget {
  const SpaceIconFrame({super.key, required this.size, this.child});

  final double size;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child:
            child ??
            DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceSunken,
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ),
      ),
    );
  }
}
