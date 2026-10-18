// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's banner, as the invite landing card shows it, for a signed-in member.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';

/// Null when the Space has no banner; a failed fetch also reads as none, since it only decorates.
final spaceBannerBytesProvider = FutureProvider.autoDispose<Uint8List?>((
  ref,
) async {
  try {
    return (await ref.watch(apiProvider).fetchSpaceBanner()).bytes;
  } on NotFoundException {
    return null;
  } on ApiException catch (error, stack) {
    reportFailure(LogTag.ui, 'load the Space banner', error, stack);
    return null;
  }
});

/// Draws nothing without a banner, so its absence leaves no gap.
class SpaceBanner extends ConsumerWidget {
  const SpaceBanner({super.key, required this.aspect});

  final double aspect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(spaceBannerBytesProvider).valueOrNull;
    if (bytes == null) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: AspectRatio(
        aspectRatio: aspect,
        child: ExcludeSemantics(child: Image.memory(bytes, fit: BoxFit.cover)),
      ),
    );
  }
}
