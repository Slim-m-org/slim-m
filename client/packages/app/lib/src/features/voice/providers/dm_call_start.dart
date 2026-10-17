// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Starting a DM call from anywhere: the channel header's call button and a
/// member's Call action share it, so both ring the same way.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dm_call.dart';
import 'dm_call_ring_controller.dart';
import 'voice_controller.dart';

/// Opens [channelId]'s call pane and rings the other person, unless this
/// device is already in (or joining) that call, where reopening the pane must
/// not ring a second time.
void startDmCall(T Function<T>(ProviderListenable<T>) read, String channelId) {
  final startingFresh = read(voiceControllerProvider).channelId != channelId;
  read(dmCallOpenProvider.notifier).state = channelId;
  if (startingFresh) {
    unawaited(
      read(dmCallRingControllerProvider.notifier).startOutgoingRing(channelId),
    );
  }
}
