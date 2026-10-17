// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this Windows copy can be moved into the per-user layout, and the
/// action that does it and restarts through the launcher.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/relaunch.dart';
import '../desktop/self_update/self_update_failure.dart';
import '../desktop/self_update/windows_adopt.dart';
import 'providers.dart';

/// True only on Windows, outside the layout, in a bundle that has a launcher.
final windowsAdoptAvailableProvider = Provider<bool>(
  (ref) =>
      Platform.isWindows && canAdoptWindowsInstall(Platform.resolvedExecutable),
);

/// Moves this copy into the layout and restarts into it. Throws a
/// [SelfUpdateFailure] and leaves this copy running when it cannot.
typedef WindowsAdoptAction = Future<void> Function();

final windowsAdoptActionProvider = Provider<WindowsAdoptAction>((ref) {
  return () async {
    final root = defaultWindowsLayoutRoot();
    if (root == null) {
      throw const SelfUpdateFailure(
        SelfUpdateFailureKind.installFailed,
        'slim-m could not find your local app data folder.',
      );
    }
    final info = await ref.read(appInfoProvider.future);
    final layout = await adoptWindowsInstall(
      executable: Platform.resolvedExecutable,
      version: info.version,
      root: root,
    );
    await spawnRelaunch(executable: layout.launcher.path);
    exit(0);
  };
});
