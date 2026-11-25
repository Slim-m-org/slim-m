// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which channel's canvas is open, as a mode of the channel rather than a route.
library;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../channels/providers/channel_by_id_provider.dart';

/// The channel whose canvas is open, or null.
///
/// A provider rather than a route: joining a call opens voice and the canvas
/// as one screen (STRATEGY), and a separate navigation step is the alternative
/// that was rejected. The cost is stated rather than discovered: no URL, no
/// deep link, and no browser back to close it. A canvas channel is the
/// exception: its route is the board, so it never reads this.
final canvasOpenProvider = StateProvider<String?>((ref) => null);

/// Whether [channel]'s board is the screen: a canvas channel always is, any other only while opened and still holding a board.
bool canvasShownFor(Channel? channel, String? openId) {
  if (channel == null) return false;
  if (channel.isCanvasChannel) return !channel.isThread;
  return openId == channel.id && channel.hasCanvas;
}

/// [canvasShownFor] for one channel id; the one answer every "is the canvas showing" reader takes.
final canvasShownProvider = Provider.autoDispose.family<bool, String>((
  ref,
  channelId,
) {
  final open = ref.watch(canvasOpenProvider);
  final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
  return canvasShownFor(channel, open);
});

/// Whether the channel is a canvas channel, whose board has no way to close.
final canvasIsChannelProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) => ref.watch(
    channelByIdProvider(
      channelId,
    ).select((c) => c.valueOrNull?.isCanvasChannel ?? false),
  ),
);

/// [close] for a voice canvas or a DM's, null for a canvas channel, which stays the board.
VoidCallback? canvasClose(
  WidgetRef ref,
  String channelId,
  VoidCallback close,
) => ref.watch(canvasIsChannelProvider(channelId)) ? null : close;
