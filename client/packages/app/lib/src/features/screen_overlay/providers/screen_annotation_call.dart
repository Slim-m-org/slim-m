// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which relayed screen marks belong to the call this client is in.
library;

import 'package:slimm_api/api.dart' as api;

/// Whether [frame] was drawn in the call on [callChannelId], so a mark from a call I left never paints.
///
/// Not the LiveKit roster: the server already seats both people, and the roster lags a fresh joiner.
bool markInCall(
  api.CanvasScreenAnnotation frame, {
  required String? callChannelId,
}) => frame.channelId == callChannelId;
