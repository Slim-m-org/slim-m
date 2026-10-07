// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one avatar for a person: their picture or initials, and optionally
/// their presence dot, resolved from the same providers on every surface.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/avatar_bytes.dart';
import '../providers/presence_devices.dart';
import '../providers/presence_view.dart';
import '../providers/providers.dart';
import '../providers/user_profiles.dart';
import 'image_decode.dart';

/// A person's picture, or their initials when they have none (or no [userId]:
/// a deleted account), at one of the [AppAvatarSize] steps.
///
/// [presence] adds the dot from [presenceForProvider], the single answer the
/// footer, the rows and the card all share; leave it off where the dot would
/// only repeat something beside it. It needs at least [AppAvatarSize.s24].
///
/// The picture's cache key comes from the signed-in user's own profile for
/// oneself, and from [userProfileProvider] for anybody else. A caller that
/// already holds the version ([UserAvatar.known]) skips that lookup.
class UserAvatar extends ConsumerWidget {
  const UserAvatar({
    super.key,
    required this.name,
    required this.userId,
    this.size = AppAvatarSize.s36,
    this.shape = AppAvatarShape.circle,
    this.presence = false,
    this.speaking = false,
    this.ringColor,
    this.semanticLabel,
    this.placeholder,
  }) : _known = null;

  const UserAvatar.known({
    super.key,
    required this.name,
    required this.userId,
    required int? avatarUpdatedAt,
    this.size = AppAvatarSize.s36,
    this.shape = AppAvatarShape.circle,
    this.presence = false,
    this.speaking = false,
    this.ringColor,
    this.semanticLabel,
    this.placeholder,
  }) : _known = (avatarUpdatedAt,);

  final String name;

  /// Null for a deleted or never-attributed author: renders initials only.
  final String? userId;
  final double size;
  final AppAvatarShape shape;
  final bool presence;
  final bool speaking;
  final Color? ringColor;
  final String? semanticLabel;

  /// Drawn instead of initials on a square avatar with no picture (a bot).
  final Widget? placeholder;

  final (int?,)? _known;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = userId;
    final version = id == null
        ? null
        : _known != null
        ? _known.$1
        : ref.watch(_avatarVersionProvider(id));
    ImageProvider? image;
    // A null version is the server's "no avatar", so asking would only 404.
    if (id != null && version != null) {
      final bytes = ref
          .watch(avatarBytesProvider((userId: id, updatedAt: version)))
          .valueOrNull;
      if (bytes != null) {
        // Floored at 3x, not the paint ratio, so a desktop scaled past 2x while under-reporting its ratio still lands a crisp avatar; the 512px source affords it. See decodeEdge.
        final edge = decodeEdge(context, size, minRatio: 3);
        image = ResizeImage(
          MemoryImage(bytes),
          width: edge,
          height: edge,
          policy: ResizeImagePolicy.fit,
        );
      }
    }
    return AppAvatar(
      name: name,
      // The id, so one person keeps one colour across every name form and every rename; see AppAvatar.tintKey.
      tintKey: id,
      image: image,
      size: size,
      shape: shape,
      status: presence && id != null
          ? ref.watch(presenceForProvider(id))
          : null,
      mobileOnly: presence && id != null
          ? ref.watch(memberMobileOnlyProvider(id))
          : false,
      speaking: speaking,
      ringColor: ringColor,
      semanticLabel: semanticLabel,
      placeholder: placeholder,
    );
  }
}

final _avatarVersionProvider = Provider.autoDispose.family<int?, String>((
  ref,
  userId,
) {
  final isSelf = ref.watch(sessionProvider).tokens?.userId == userId;
  if (isSelf) {
    return ref.watch(
      meProvider.select((me) => me.valueOrNull?.avatarUpdatedAt),
    );
  }
  return ref.watch(
    userProfileProvider(userId).select((p) => p.valueOrNull?.avatarUpdatedAt),
  );
});
