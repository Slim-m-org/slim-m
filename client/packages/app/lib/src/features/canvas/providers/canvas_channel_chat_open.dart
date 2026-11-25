// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a canvas channel's chat is docked open, kept per channel.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Closed until opened, and its own per channel: the voice chat flag is one global bool, which would leave chat docked in every canvas channel.
final canvasChannelChatOpenProvider = StateProvider.family<bool, String>(
  (ref, channelId) => false,
);
