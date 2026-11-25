// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a channel has a board, and whether a control may offer to open one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../channels/providers/channel_by_id_provider.dart';

/// Whether the channel is known to have a board now; false until its row loads, so nothing reads a board that may be closed.
final channelHasCanvasProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) => ref.watch(
    channelByIdProvider(
      channelId,
    ).select((c) => c.valueOrNull?.hasCanvas ?? false),
  ),
);

/// Whether a control may offer to open this channel's board: a canvas channel is its own board, a closed one offers nothing, and an unloaded row keeps the old rule.
final canvasEntryProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) => ref.watch(
    channelByIdProvider(channelId).select((c) {
      final row = c.valueOrNull;
      return row == null || (row.hasCanvas && !row.isCanvasChannel);
    }),
  ),
);
