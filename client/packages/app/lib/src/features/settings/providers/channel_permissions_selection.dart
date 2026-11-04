// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel whose permissions are open, shared by the pane and its heading.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' show Channel;

/// Null shows the channel list; the heading's back arrow clears it.
final channelPermissionsSelectionProvider = StateProvider.autoDispose<Channel?>(
  (ref) => null,
);
