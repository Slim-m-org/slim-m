// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this install tells the server about itself when it signs in.
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The handle this install's secret is stored under, in the key store.
///
/// Survives sign-out on purpose: the server uses the id made from it to give
/// one install one row in the devices list however often it signs in. A
/// reinstall wipes the key store, so a reinstall is a new device.
const installIdHandle = 'install_id';

/// This install's id for [server], making and storing the secret on first use.
/// Null when the store cannot be used, in which case the server treats the
/// sign-in as a new device, as it always did.
///
/// A keyed hash of the secret and the server's origin, so each server keeps a
/// stable id of its own and two deployments cannot match theirs up.
Future<String?> loadInstallId(KeyStore store, Uri server) async {
  try {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(server.origin),
      secretKey: SecretKey(utf8.encode(await _installSecret(store))),
    );
    return [
      for (final byte in mac.bytes.take(16))
        byte.toRadixString(16).padLeft(2, '0'),
    ].join();
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.auth,
      "Could not read this install's id; signing in without it",
      error,
      stack,
    );
    return null;
  }
}

Future<String> _installSecret(KeyStore store) async {
  final stored = await store.read(installIdHandle);
  if (stored != null && stored.isNotEmpty) return stored;
  final random = Random.secure();
  final fresh = List.generate(
    32,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  await store.put(installIdHandle, fresh);
  return fresh;
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
  required Uri server,
}) async {
  final clientVersion = await appInfo
      .then<String?>((info) => info.version)
      .catchError((Object error, StackTrace stack) {
        AppLog.swallowed(
          LogTag.platform,
          'Could not read the app version; signing in without it',
          error,
          stack,
        );
        return null;
      });
  return SignInIdentity(
    deviceName: await resolveDeviceName(),
    clientKind: deviceClientKind,
    clientVersion: clientVersion,
    installId: await loadInstallId(keyStore, server),
  );
}
