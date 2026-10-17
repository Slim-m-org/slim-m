// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last non-voice conversation the shell showed, so hanging up a phone
/// call has somewhere to land that is not the voice channel's own screen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Null until a text channel or DM has been shown this session.
final lastTextChannelProvider = StateProvider<String?>((ref) => null);

/// The text channel shown before [lastTextChannelProvider], for when the last
/// one is the very channel that just went away.
final previousTextChannelProvider = StateProvider<String?>((ref) => null);

/// Channels deleted this session, by id, with the name they had, so a screen
/// still showing one can leave with a word about why.
final deletedChannelsProvider = StateProvider<Map<String, String>>(
  (ref) => const {},
);

/// Where to go when [gone] disappears from under the screen: the [last] text
/// channel, else the [previous] one, never [gone] itself.
String? fallbackChannel({
  required String? last,
  required String? previous,
  required String gone,
}) {
  if (last != null && last != gone) return last;
  if (previous != null && previous != gone) return previous;
  return null;
}

/// Temporary rooms (decision 0065) removed this session, so a screen still
/// showing one can leave for [lastTextChannelProvider] instead of reading as
/// a channel that was never found.
final removedRoomsProvider = StateProvider<Set<String>>((ref) => const {});
