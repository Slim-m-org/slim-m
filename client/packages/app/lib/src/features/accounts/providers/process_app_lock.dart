// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one app lock every account's container reads.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'dart:async';

import 'package:slimm_platform/platform.dart';

import '../../../providers/app_lock_controller.dart';
import '../../../providers/app_lock_preference.dart';
import 'account_host.dart';

/// A lock over [host]'s accounts, so no switch or link lands past it.
///
/// Reads the on-screen account's preference and sign-in state through [host],
/// and starts its grace window when [sessionLock] reports the session leaving.
AppLockController createProcessAppLock(
  AccountHost host, {
  SessionLockChannel? sessionLock,
}) {
  AccountRuntime? onScreen() =>
      host.active ?? (host.runtimes.isEmpty ? null : host.runtimes.first);
  final signedInChanges = StreamController<bool>.broadcast();
  bool anySignedIn() => host.runtimes.any((r) => r.signedIn);
  host.addListener(() => signedInChanges.add(anySignedIn()));
  final controller = AppLockController.shared(
    AppLockHost(
      enabled: () =>
          onScreen()?.container.read(appLockPreferenceProvider) ?? false,
      signedIn: anySignedIn,
      signedInChanges: signedInChanges.stream,
      channel: () =>
          onScreen()?.container.read(biometricAuthChannelProvider) ??
          BiometricAuthChannel(),
      disable: () async {
        await onScreen()?.container
            .read(appLockPreferenceProvider.notifier)
            .set(false);
      },
      releaseShield: () async {
        await onScreen()?.container
            .read(appLockWindowChannelProvider)
            .releasePrivacyShield();
      },
    ),
  );
  (sessionLock ?? SessionLockChannel()).listen(
    away: controller.markAway,
    back: controller.markBack,
  );
  return controller;
}
