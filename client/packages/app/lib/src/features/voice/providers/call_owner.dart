// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which account container a device-wide call event belongs to.
///
/// Native channels (CallKit, the foreground service, global hotkeys,
/// picture-in-picture) exist once per process while every account has its own
/// container, so each container asks here before acting on one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../accounts/providers/account_host.dart';
import '../../accounts/providers/account_providers.dart';

/// The container in a call, else the one on screen; null with no account host.
ProviderContainer? callEventContainer(AccountHost? host) =>
    (host?.callRuntime ?? host?.active)?.container;

/// Whether [ref]'s container is the one native call events should reach.
///
/// A container with no account host (single account, tests) always is.
bool ownsCallEvents(Ref ref) {
  final owner = callEventContainer(ref.read(accountHostProvider));
  return owner == null || identical(owner, ref.container);
}

/// Whether a container other than [ref]'s is in a call.
bool otherAccountInCall(Ref ref) {
  final host = ref.read(accountHostProvider);
  if (host == null) return false;
  return host.runtimes.any(
    (r) => r.inCall && !identical(r.container, ref.container),
  );
}
