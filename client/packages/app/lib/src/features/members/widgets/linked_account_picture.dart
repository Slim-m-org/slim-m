// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A linked account's picture, round, or [fallback] when it has none.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../messages/widgets/image_decode.dart';
import '../providers/linked_avatar_bytes.dart';

class LinkedAccountPicture extends ConsumerWidget {
  const LinkedAccountPicture({
    super.key,
    required this.userId,
    required this.account,
    required this.size,
    required this.fallback,
  });

  final String userId;
  final api.LinkedAccount account;
  final double size;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updatedAt = account.avatarUpdatedAt;
    if (updatedAt == null) return fallback;
    final bytes = ref
        .watch(
          linkedAvatarBytesProvider((userId: userId, updatedAt: updatedAt)),
        )
        .valueOrNull;
    if (bytes == null) return fallback;
    final edge = decodeEdge(context, size, minRatio: 2, oversample: 3);
    return ExcludeSemantics(
      child: AppAvatar(
        name: account.username,
        size: size,
        image: ResizeImage(
          MemoryImage(bytes),
          width: edge,
          height: edge,
          policy: ResizeImagePolicy.fit,
        ),
      ),
    );
  }
}
