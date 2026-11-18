// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this viewer watches a channel's canvas without drawing on it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../permissions.dart';
import '../../channels/providers/channel_permissions.dart';

/// True once the channel's permissions hold `VIEW_CHANNEL` without `USE_CANVAS`;
/// false while they load, so a member who can draw never sees the tools blink away.
final canvasSpectatingProvider = Provider.autoDispose.family<bool, String>((
  ref,
  channelId,
) {
  final permissions = ref
      .watch(channelPermissionsProvider(channelId))
      .valueOrNull;
  return permissions != null &&
      permissions.hasPermission(Perm.viewChannel) &&
      !permissions.hasPermission(Perm.useCanvas);
});
