// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which relayed screen marks belong to the call this client is in.
library;

import 'package:slimm_api/api.dart' as api;

/// Whether [frame] was drawn in the call on [callChannelId], by someone in [callMembers] over the screen of someone in it.
///
/// The rule the server relays by, kept here too so a server without it cannot paint a mark from another call.
bool markInCall(
  api.CanvasScreenAnnotation frame, {
  required String? callChannelId,
  required Iterable<String> callMembers,
}) =>
    frame.channelId == callChannelId &&
    callMembers.contains(frame.userId) &&
    callMembers.contains(frame.targetUserId);
