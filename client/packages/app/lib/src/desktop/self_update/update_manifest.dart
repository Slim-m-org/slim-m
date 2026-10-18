// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Verifying and reading the signed release manifest built by
/// `scripts/update-manifest.py`. Order matters: signature over the exact
/// bytes first, then schema, then the platform's artifact.
library;

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'self_update_failure.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const supportedManifestSchema = 1;

/// One platform's downloadable file, as the signed manifest names it.
class UpdateArtifact {
  const UpdateArtifact({
    required this.url,
    required this.sha256,
    required this.size,
  });

  final Uri url;
  final String sha256;
  final int size;
}

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.tag,
    required this.artifacts,
  });

  final String version;
  final String tag;
  final Map<String, UpdateArtifact> artifacts;
}

/// Whether [version] is exactly `major.minor.patch` in digits, the only shape
/// allowed to name a directory on disk.
bool isPlainVersion(String version) =>
    RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version);

/// The CPU architecture this process runs on, as `Platform.version` names it
/// (`x64`, `arm64`, ...), without needing dart:ffi.
String hostArchitecture([String? dartVersion]) {
  final match = RegExp(
    r'on "[a-z]+_([a-z0-9]+)"',
  ).firstMatch(dartVersion ?? Platform.version);
  return match?.group(1) ?? 'unknown';
}

/// The manifest's platform key for this host, or null where there is none.
String? updatePlatformKey({required String os, required String arch}) {
  switch (os) {
    case 'linux':
      return arch == 'x64' ? 'linux-x64' : null;
    case 'windows':
      return arch == 'x64' ? 'windows-x64' : null;
    case 'macos':
      return 'macos';
  }
  return null;
}

/// Whether [signatureBase64] is a valid signature of [manifestBytes] by any
/// key in [trustedKeys].
Future<bool> manifestSignatureIsValid({
  required Uint8List manifestBytes,
  required String signatureBase64,
  required List<String> trustedKeys,
}) async {
  final Uint8List signature;
  try {
    signature = base64.decode(signatureBase64.trim());
  } on FormatException catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'host architecture failed, ignored',
      error,
      stack,
    );
    return false;
  }
  if (signature.length != 64) return false;
  final algorithm = Ed25519();
  for (final key in trustedKeys) {
    final Uint8List keyBytes;
    try {
      keyBytes = base64.decode(key);
    } on FormatException catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'host architecture failed, ignored',
        error,
        stack,
      );
      continue;
    }
    final valid = await algorithm.verify(
      manifestBytes,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (valid) return true;
  }
  return false;
}

/// Parses signed [manifestBytes]; throws a [SelfUpdateFailure] when the shape
/// or schema is not one this build understands.
UpdateManifest parseManifest(Uint8List manifestBytes) {
  const bad = SelfUpdateFailure(
    SelfUpdateFailureKind.badManifest,
    'The update information was not in a form this version understands.',
  );
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(manifestBytes));
  } on FormatException {
    throw bad;
  }
  if (decoded is! Map<String, dynamic>) throw bad;
  final schema = decoded['schema'];
  if (schema != supportedManifestSchema) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.unsupportedSchema,
      'This update needs a newer version of slim-m to install it.',
      detail: 'manifest schema $schema, supported $supportedManifestSchema',
    );
  }
  final version = decoded['version'];
  final tag = decoded['tag'];
  final raw = decoded['artifacts'];
  if (version is! String || tag is! String || raw is! Map<String, dynamic>) {
    throw bad;
  }
  final artifacts = <String, UpdateArtifact>{};
  for (final entry in raw.entries) {
    final artifact = _parseArtifact(entry.value);
    if (artifact != null) artifacts[entry.key] = artifact;
  }
  return UpdateManifest(version: version, tag: tag, artifacts: artifacts);
}

UpdateArtifact? _parseArtifact(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  final url = value['url'];
  final sha256 = value['sha256'];
  final size = value['size'];
  if (url is! String || sha256 is! String || size is! int) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || size <= 0) return null;
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) return null;
  return UpdateArtifact(url: uri, sha256: sha256, size: size);
}
