// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The verify-and-download half of decision 0041: fetch the signed manifest
/// from the latest client release, check it, and download the artifact for
/// this platform into staging. Nothing here applies or swaps anything.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../update_check.dart';
import 'latest_client_release.dart';
import 'self_update_failure.dart';
import 'update_download.dart';
import 'update_keys.dart';
import 'update_manifest.dart';

const _timeout = Duration(seconds: 15);
const _maxManifestBytes = 256 * 1024;

/// A downloaded, hash-checked artifact waiting in the staging directory.
///
/// Only [fetchVerifiedUpdate] can build one, so an install can never be handed
/// a file that skipped the signature, hash and platform checks.
class VerifiedUpdate {
  const VerifiedUpdate._({
    required this.version,
    required this.tag,
    required this.file,
  });

  /// Skips every check; for tests that exercise an install step on its own.
  @visibleForTesting
  const factory VerifiedUpdate.forTest({
    required String version,
    required String tag,
    required File file,
  }) = VerifiedUpdate._;

  final String version;
  final String tag;
  final File file;
}

/// Returns the verified download for [platformKey], or null when the newest
/// release is not newer than [currentVersion]. Throws [SelfUpdateFailure] for
/// every other stop, including a manifest with no artifact for this platform,
/// which must never read as "nothing to do"; the staging
/// directory then holds no finished file.
Future<VerifiedUpdate?> fetchVerifiedUpdate({
  required String currentVersion,
  required String platformKey,
  required Directory stagingDir,
  required http.Client client,
}) => fetchVerifiedUpdateWith(
  currentVersion: currentVersion,
  platformKey: platformKey,
  stagingDir: stagingDir,
  client: client,
);

/// [fetchVerifiedUpdate] with the trusted keys and free-space probe exposed,
/// so a test can sign with its own key; production never passes either.
@visibleForTesting
Future<VerifiedUpdate?> fetchVerifiedUpdateWith({
  required String currentVersion,
  required String platformKey,
  required Directory stagingDir,
  required http.Client client,
  List<String> trustedKeys = trustedUpdateKeys,
  FreeSpace freeSpace = freeSpaceOf,
}) async {
  final tag = await _latestClientTag(client);
  if (tag == null) return null;
  final base = 'https://github.com/$clientReleaseRepo/releases/download/$tag';
  final manifestBytes = await _getBytes(
    client,
    Uri.parse('$base/manifest.json'),
  );
  final signature = utf8.decode(
    await _getBytes(client, Uri.parse('$base/manifest.json.sig')),
    allowMalformed: true,
  );
  final signed = await manifestSignatureIsValid(
    manifestBytes: manifestBytes,
    signatureBase64: signature,
    trustedKeys: trustedKeys,
  );
  if (!signed) {
    throw const SelfUpdateFailure(
      SelfUpdateFailureKind.badSignature,
      'The update could not be verified, so it was not installed.',
    );
  }
  final manifest = parseManifest(manifestBytes);
  if (!isPlainVersion(manifest.version)) {
    throw const SelfUpdateFailure(
      SelfUpdateFailureKind.badManifest,
      'The update information was not in a form this version understands.',
    );
  }
  if (!isNewer(manifest.version, currentVersion)) return null;
  final artifact = manifest.artifacts[platformKey];
  if (artifact == null) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.noArtifactForPlatform,
      'Version ${manifest.version} is out, but it has no download for this '
      'platform yet, so it cannot install itself. Get it from the release '
      'page instead.',
      detail: 'manifest lists: ${manifest.artifacts.keys.join(', ')}',
      releaseUrl:
          'https://github.com/$clientReleaseRepo/releases/tag/${manifest.tag}',
    );
  }
  final file = await downloadArtifact(
    artifact: artifact,
    stagingDir: stagingDir,
    client: client,
    freeSpace: freeSpace,
  );
  return VerifiedUpdate._(
    version: manifest.version,
    tag: manifest.tag,
    file: file,
  );
}

Future<String?> _latestClientTag(http.Client client) async {
  final bytes = await _getBytes(
    client,
    Uri.parse(
      'https://api.github.com/repos/$clientReleaseRepo/releases?per_page=30',
    ),
  );
  final Object? releases;
  try {
    releases = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } on FormatException catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.unreachable,
      'Could not reach the update server.',
      detail: '$error',
    );
  }
  if (releases is! List) return null;
  return latestClientRelease(releases)?.tag;
}

Future<Uint8List> _getBytes(http.Client client, Uri url) async {
  try {
    final response = await client.get(url).timeout(_timeout);
    if (response.statusCode != 200 ||
        response.bodyBytes.length > _maxManifestBytes) {
      throw HttpException('status ${response.statusCode}', uri: url);
    }
    return response.bodyBytes;
  } catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.unreachable,
      'Could not reach the update server.',
      detail: '$error',
    );
  }
}
