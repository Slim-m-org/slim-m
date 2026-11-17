// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a call holds the device's audio session. Each community is its own
/// container, but a call left running in one still holds the phone's one
/// session while another is on screen (decision 0068).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/accounts/providers/account_providers.dart';
import '../features/voice/providers/voice_flags.dart';

/// Whether any signed-in community's account is in a call.
final callInAnotherAccountProvider = Provider<bool Function()>(
  (ref) =>
      () => ref.read(accountHostProvider)?.callRuntime != null,
);

/// This container's call, or one in another community.
final callHoldsAudioSessionProvider = Provider<bool Function()>(
  (ref) =>
      () =>
          ref.read(voiceFlagsProvider).channelId != null ||
          ref.read(callInAnotherAccountProvider)(),
);
