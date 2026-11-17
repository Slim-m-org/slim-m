// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When first-run setup is owed, where it lands, and how its flags are keyed.
library;

import 'package:slimm_data/data.dart' show Channel;

import '../../../push/providers/push_controller.dart' show PushStatus;

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

/// The Space's first text channel: the oldest one this member can read,
/// earliest in the rail on a tie.
///
/// That is the channel a Space starts with, usually #general, where a
/// newcomer is expected; the busiest one can be any long-running thread.
Channel? pickLandingChannel(List<Channel> channels) {
  Channel? first;
  for (final channel in channels) {
    if (channel.kind != 'text') continue;
    if (first == null || channel.createdAt < first.createdAt) first = channel;
  }
  return first;
}

/// Whether the notifications step should ask the OS before offering levels.
///
/// Only a device that can be pushed to and has not answered yet: desktop is
/// unsupported, and a blocked or registered device has already answered.
bool firstRunAsksPermission(PushStatus status) =>
    status == PushStatus.noTokenYet || status == PushStatus.registrationFailed;
