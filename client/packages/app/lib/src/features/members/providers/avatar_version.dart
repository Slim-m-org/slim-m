// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The cache version of one person's avatar, which is the null that means they have none.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import 'user_profiles.dart';

/// The signed-in user's own profile answers for oneself, [userProfileProvider] for anybody else.
final avatarVersionProvider = Provider.autoDispose.family<int?, String>((
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
