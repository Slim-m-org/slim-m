// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this install tells the server about itself when it signs in.
library;

import 'dart:math';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_platform/platform.dart';

/// The handle this install's id is stored under, in the key store.
///
/// Survives sign-out on purpose: the server uses it to give one install one
/// row in the devices list however often it signs in. A reinstall wipes the
/// key store, so a reinstall is a new device.
const installIdHandle = 'install_id';

/// Reads this install's id, making and storing one on first use. Null when
/// the store cannot be used, in which case the server treats the sign-in as
/// a new device, as it always did.
Future<String?> loadInstallId(KeyStore store) async {
  try {
    final stored = await store.read(installIdHandle);
    if (stored != null && stored.isNotEmpty) return stored;
    final random = Random.secure();
    final fresh = List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    await store.put(installIdHandle, fresh);
    return fresh;
  } catch (_) {
    return null;
  }
}

/// The fields every sign-in and registration sends about this device.
class SignInIdentity {
  const SignInIdentity({
    required this.deviceName,
    required this.clientKind,
    required this.clientVersion,
    required this.installId,
  });

  final String deviceName;
  final String clientKind;
  final String? clientVersion;
  final String? installId;
}

/// Best-effort throughout: a version, model or id this build cannot read is
/// worth losing, not worth blocking sign-in over.
Future<SignInIdentity> signInIdentity({
  required KeyStore keyStore,
  required Future<PackageInfo> appInfo,
}) async {
  final clientVersion = await appInfo
      .then<String?>((info) => info.version)
      .catchError((_) => null);
  return SignInIdentity(
    deviceName: await resolveDeviceName(),
    clientKind: deviceClientKind,
    clientVersion: clientVersion,
    installId: await loadInstallId(keyStore),
  );
}
