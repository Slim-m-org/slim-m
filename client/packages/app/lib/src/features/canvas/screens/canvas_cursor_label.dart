// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../members/providers/user_profiles.dart';

/// A remote cursor's label as of the last resolved answer, starting a fetch
/// for an id this session has not asked about yet.
///
/// Takes the provider-side [Ref] because `resolveAuthorProfiles` wants a
/// `WidgetRef`, which the canvas engine never holds.
String canvasCursorLabel(Ref ref, String userId) {
  final profiles = ref.read(batchProfilesControllerProvider);
  unawaited(
    ref.read(batchProfilesControllerProvider.notifier).resolve({userId}),
  );
  if (profiles.containsKey(userId)) {
    return profiles[userId]?.displayName ?? 'Deleted user';
  }
  return 'Someone';
}
