// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this computer starts the app at sign-in, read back from the system.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

/// This host's login launch, or null where there is none.
final autostartProvider = FutureProvider<Autostart?>((ref) => hostAutostart());

/// The registration as the system reports it now; never a stored guess.
final autostartEnabledProvider = FutureProvider.autoDispose<bool>((ref) async {
  final autostart = await ref.watch(autostartProvider.future);
  return autostart != null && await autostart.isEnabled();
});
