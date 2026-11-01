// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Trading this iPhone's push token for a fresh one and registering it, for an
/// install whose token Apple accepts but never delivers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'push_controller.dart';

/// False when there was nothing to reset, off iOS or on an older build.
Future<bool> resetPushRegistration(WidgetRef ref) async {
  final reset = await ref.read(apnsTokenChannelProvider).resetRegistration();
  if (!reset) return false;
  await ref.read(pushControllerProvider.notifier).register();
  return true;
}
