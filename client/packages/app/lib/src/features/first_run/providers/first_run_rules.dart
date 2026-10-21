// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When first-run setup is owed, where it lands, and how its flags are keyed.
library;

import 'package:slimm_data/data.dart' show Channel;

/// An account older than this has had its chance to find its way around.
const firstRunWindow = Duration(days: 1);

const _doneKeyPrefix = 'slimm.first_run.done.';

/// One flag per account per Space, so a second Space on the device starts clean.
String firstRunDoneKey(String space, String accountId) =>
    '$_doneKeyPrefix$space|$accountId';

bool firstRunDue({
  required bool done,
  required int accountCreatedAtMs,
  required bool hasOwnMessages,
  required DateTime now,
}) {
  if (done || hasOwnMessages) return false;
  final age = now.difference(
    DateTime.fromMillisecondsSinceEpoch(accountCreatedAtMs),
  );
  return age < firstRunWindow;
}

/// The text channel with the most history, earliest in the rail on a tie.
///
/// The local store only holds channels this member can read, and its `cursor`
/// is the highest message sequence seen, which is the cheapest honest measure
/// of how active a channel is.
Channel? pickLandingChannel(List<Channel> channels) {
  Channel? best;
  for (final channel in channels) {
    if (channel.kind != 'text') continue;
    if (best == null || channel.cursor > best.cursor) best = channel;
  }
  return best;
}
