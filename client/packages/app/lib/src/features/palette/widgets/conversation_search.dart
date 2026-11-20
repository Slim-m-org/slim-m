// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A conversation's search button: the palette's message search with that
/// conversation already filled in as a removable `in:` chip.
library;

import 'package:flutter/widgets.dart';

import '../../messages/providers/message_search_query.dart';
import 'command_palette.dart';

/// Opens the palette scoped to [channelId], its chip reading [label].
Future<void> openConversationSearch(
  BuildContext context, {
  required String channelId,
  required String label,
}) => openCommandPalette(
  context,
  scope: SearchFilter(
    SearchKey.inChannel,
    label.startsWith('#') ? label.substring(1) : label,
    label: label,
    channelId: channelId,
  ),
);

/// What a conversation's chip calls it: `#name` for a channel, a DM or group by its name.
String conversationSearchLabel({
  required String name,
  bool isDm = false,
  bool isThread = false,
}) {
  if (isThread) return 'this thread';
  if (name.isEmpty) return 'this conversation';
  return isDm ? name : '#$name';
}
