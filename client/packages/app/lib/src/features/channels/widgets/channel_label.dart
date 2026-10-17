// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a channel is named when it is referred to from somewhere else.
///
/// Written twice before this existed - once in `forwarded_message_card.dart`
/// and once in `saved_messages_sheet.dart`, hours apart - which is one copy
/// per surface that has to say where something came from. A third would have
/// been a third copy, and the first variant anybody adds (a personal space,
/// a thread) would have landed in one of them.
library;

import 'package:slimm_data/data.dart';

/// `#general` for an ordinary channel, the person's own name for a DM, or
/// null when this client does not hold the channel at all.
///
/// Null is the load-bearing case rather than a fallback: the server sends a
/// channel id and never its name, so a channel absent from this client's own
/// list is one the reader cannot see. Callers show no location for it and
/// offer no jump, which is the same answer asking the server would give.
///
/// A DM is named by the person because a DM has no name a `#` would make
/// sense of.
String? channelDisplayLabel(Channel? channel) {
  if (channel == null) return null;
  if (channel.dmParticipantId != null) return channel.name;
  return '#${channel.name}';
}
