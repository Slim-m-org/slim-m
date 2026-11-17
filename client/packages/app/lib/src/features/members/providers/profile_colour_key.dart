// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One person's profile colour as the server holds it, for an avatar that only has their id.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import 'user_profiles.dart';

/// A preset [index] or a custom [rgb], both null while the profile is unknown.
typedef ProfileColourKey = ({int? index, int? rgb});

/// The signed-in user's own profile answers for oneself, [userProfileProvider]
/// for anybody else: the same reads the avatar's picture version already makes.
final profileColourKeyProvider = Provider.autoDispose
    .family<ProfileColourKey, String>((ref, userId) {
      final isSelf = ref.watch(sessionProvider).tokens?.userId == userId;
      if (isSelf) {
        return ref.watch(
          meProvider.select(
            (me) => (
              index: me.valueOrNull?.profileColor,
              rgb: me.valueOrNull?.profileColorRgb,
            ),
          ),
        );
      }
      return ref.watch(
        userProfileProvider(userId).select(
          (p) => (
            index: p.valueOrNull?.profileColor,
            rgb: p.valueOrNull?.profileColorRgb,
          ),
        ),
      );
    });
