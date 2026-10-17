// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a message author resolves to a bot; false until the profile loads.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../members/providers/user_profiles.dart';

final authorIsBotProvider = Provider.family<bool, String?>(
  (ref, authorId) => ref.watch(
    batchProfilesControllerProvider.select(
      (m) => authorResolution(m, authorId ?? '').profile?.isBot ?? false,
    ),
  ),
);
