// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this computer starts the app at sign-in, read back from the system.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart';

/// This host's login launch, or null where there is none.
final autostartProvider = FutureProvider<Autostart?>((ref) => hostAutostart());

/// The registration as the system reports it now; never a stored guess.
final autostartEnabledProvider = FutureProvider.autoDispose<bool>((ref) async {
  final autostart = await ref.watch(autostartProvider.future);
  return autostart != null && await autostart.isEnabled();
});

/// Points an existing login registration at this install's stable launcher, so an old versioned path stops starting a stale or deleted build.
Future<void> repairAutostart(ProviderContainer container) async {
  try {
    final autostart = await container.read(autostartProvider.future);
    await autostart?.repair();
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Could not repair the start-on-login entry',
      error,
      stack,
    );
  }
}
