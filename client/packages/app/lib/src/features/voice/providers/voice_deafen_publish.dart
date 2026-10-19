// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the call that this client deafened itself, so the others see the icon.
library;

import 'package:slimm_api/api.dart' as api;

/// A failure only costs the icon, so it is logged by the caller and not shown.
Future<void> publishDeafened(
  api.SlimmApi client,
  String? channelId, {
  required bool deafened,
  void Function(Object error)? onError,
}) async {
  if (channelId == null) return;
  try {
    await client.setVoiceDeafened(channelId, deafened: deafened);
  } on Object catch (error) {
    onError?.call(error);
  }
}
