// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one definition of "you are the only one in this call", shared by the
/// stage's calm waiting hint and the local hold music so they cannot disagree.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_flags.dart';

bool isAloneInCall(List<VoiceParticipant> participants) =>
    participants.length == 1;

/// Whether the live call has only you in it; the dock's solo controls follow it.
final callAloneProvider = Provider<bool>(
  (ref) => isAloneInCall(ref.watch(voiceParticipantsProvider)),
);

/// Whether anyone besides you is in the live call; the canvas dock lists people only then.
final callHasOthersProvider = Provider<bool>(
  (ref) => ref.watch(voiceParticipantsProvider).any((p) => !p.isLocal),
);
