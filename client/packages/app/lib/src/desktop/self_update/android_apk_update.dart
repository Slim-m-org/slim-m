// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sideloaded apk updates itself the way the desktop builds do, through the
/// same signed manifest, but Android only lets the system installer replace
/// an app, so the last step is handing it the verified file to confirm.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'install_fs.dart';
import 'self_update.dart';
import 'self_update_failure.dart';

/// The key the signed manifest lists the apk under; see scripts/update-manifest.py.
const androidUpdatePlatformKey = 'android';

/// The cache subdirectory the app's FileProvider shares with the installer.
const androidUpdateCacheDir = 'updates';

enum ApkInstallOutcome {
  /// The system installer is showing its confirmation.
  started,

  /// Android sent the user to allow installs from slim-m first; trying again
  /// after that continues.
  needsPermission,
}

abstract interface class ApkInstaller {
  Future<ApkInstallOutcome> install(File apk);
}

class ChannelApkInstaller implements ApkInstaller {
  const ChannelApkInstaller();

  static const _channel = MethodChannel('top.npcserver.slimm/apk_install');

  @override
  Future<ApkInstallOutcome> install(File apk) async {
    final result = await _channel.invokeMethod<String>('install', apk.path);
    return result == 'needs_permission'
        ? ApkInstallOutcome.needsPermission
        : ApkInstallOutcome.started;
  }
}

typedef FetchVerifiedUpdate =
    Future<VerifiedUpdate?> Function({
      required String currentVersion,
      required String platformKey,
      required Directory stagingDir,
      required http.Client client,
    });

/// Deletes everything staged in [staging] except [keep], so the folder never
/// holds more than the apk being installed. The system installer reads that
/// file after this returns, which is why it cannot be deleted here.
void pruneStagedUpdates(Directory staging, {File? keep}) {
  if (!staging.existsSync()) return;
  for (final entry in staging.listSync(followLinks: false)) {
    if (keep == null || !p.equals(entry.path, keep.path)) safeDelete(entry);
  }
}

/// Downloads and verifies the newest apk, then hands it to [installer].
/// Null when nothing is newer; a [SelfUpdateFailure] when it cannot be had.
Future<ApkInstallOutcome?> updateAndroidApk({
  required String currentVersion,
  required Directory cacheDir,
  required http.Client client,
  ApkInstaller installer = const ChannelApkInstaller(),
  FetchVerifiedUpdate fetch = fetchVerifiedUpdate,
}) async {
  final staging = Directory('${cacheDir.path}/$androidUpdateCacheDir');
  final update = await fetch(
    currentVersion: currentVersion,
    platformKey: androidUpdatePlatformKey,
    stagingDir: staging,
    client: client,
  );
  pruneStagedUpdates(staging, keep: update?.file);
  if (update == null) return null;
  try {
    return await installer.install(update.file);
  } on PlatformException catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.installFailed,
      'The update downloaded, but Android would not open it. '
      'Get it from the release page instead.',
      detail: '$error',
    );
  }
}

/// The whole update from the running [currentVersion]; a provider so the
/// banner's tests can swap it for a fake.
final apkUpdateRunnerProvider =
    Provider<Future<ApkInstallOutcome?> Function(String currentVersion)>(
      (ref) => (currentVersion) async {
        final client = http.Client();
        try {
          return await updateAndroidApk(
            currentVersion: currentVersion,
            cacheDir: await getTemporaryDirectory(),
            client: client,
          );
        } finally {
          client.close();
        }
      },
    );

/// True while the apk downloads, so the banner cannot start a second one.
final apkUpdateBusyProvider = StateProvider<bool>((ref) => false);
