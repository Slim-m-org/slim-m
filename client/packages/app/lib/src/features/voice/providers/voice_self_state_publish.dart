// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the call that this client muted or deafened itself, so the others see the icon.
library;

import 'package:slimm_api/api.dart' as api;

/// A failure only costs the icon, so it is logged by the caller and not shown.
Future<void> publishDeafened(
  api.SlimmApi client,
  String? channelId, {
  required bool deafened,
  void Function(Object error)? onError,
}) => _publish(
  channelId,
  (id) => client.setVoiceDeafened(id, deafened: deafened),
  onError,
);

/// [publishDeafened] for the microphone, which tells viewers outside the call.
Future<void> publishMuted(
  api.SlimmApi client,
  String? channelId, {
  required bool muted,
  void Function(Object error)? onError,
}) => _publish(
  channelId,
  (id) => client.setVoiceMuted(id, muted: muted),
  onError,
);

Future<void> _publish(
  String? channelId,
  Future<void> Function(String channelId) send,
  void Function(Object error)? onError,
) async {
  if (channelId == null) return;
  try {
    await send(channelId);
  } on Object catch (error) {
    onError?.call(error);
  }
}
