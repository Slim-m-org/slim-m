// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail header's Space identity: the icon carrying the connection dot.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/sync_controller.dart';
import '../providers/sync_failure.dart';
import 'channel_rail_frame.dart';
import 'space_icon.dart';

/// With an icon the dot is its bottom-right badge, as on an avatar; without one it stands alone.
class SpaceIdentityMark extends ConsumerWidget {
  const SpaceIdentityMark({
    super.key,
    required this.iconUpdatedAt,
    required this.status,
    this.failure,
  });

  final int? iconUpdatedAt;
  final SyncStatus status;
  final SyncFailure? failure;

  static const double iconSize = AppSizes.icon20;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (iconUpdatedAt == null) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: SpaceConnectionDot(status: status, failure: failure),
      );
    }
    const halo = SpaceConnectionDot.haloedSize;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.s8),
      child: SizedBox.square(
        dimension: iconSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SpaceIcon(updatedAt: iconUpdatedAt, size: iconSize),
            // Centred on the corner, nudged in because the icon is a rounded square.
            Positioned(
              left: iconSize - halo / 2 - 1,
              top: iconSize - halo / 2 - 1,
              child: SpaceConnectionDot(
                status: status,
                failure: failure,
                haloed: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
