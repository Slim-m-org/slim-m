// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the server knows canvas channels; an older one hides every control for them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/server_info.dart';

final canvasChannelsSupportedProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(serverInfoProvider).valueOrNull?.canvasChannels ?? false,
);
