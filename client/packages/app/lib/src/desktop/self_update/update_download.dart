// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Downloading a manifest artifact into the staging directory. The bytes live
/// in a `.part` file until size and sha256 both match, and only then get their
/// real name, so nothing half-written is ever mistaken for a staged update.
library;

import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'self_update_failure.dart';
import 'update_manifest.dart';

/// Free bytes on the volume holding a directory, or null when unknown.
typedef FreeSpace = Future<int?> Function(Directory directory);

const _maxAttempts = 3;

/// Free bytes via `df` or PowerShell; null when the tool is missing or odd.
Future<int?> freeSpaceOf(Directory directory) async {
  try {
    if (Platform.isWindows) {
      final drive = p.rootPrefix(directory.absolute.path).substring(0, 1);
      final done = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-PSDrive $drive).Free',
      ]);
      return int.tryParse((done.stdout as String).trim());
    }
    final done = await Process.run('df', ['-Pk', directory.path]);
    final lines = (done.stdout as String).trim().split('\n');
    final kilobytes = int.tryParse(lines.last.trim().split(RegExp(r'\s+'))[3]);
    return kilobytes == null ? null : kilobytes * 1024;
  } catch (_) {
    return null;
  }
}

/// Downloads [artifact] into [stagingDir] and returns the verified file.
/// Throws a [SelfUpdateFailure] and leaves no file behind on a size or hash
/// mismatch; a transport failure keeps the `.part` so a retry resumes it.
Future<File> downloadArtifact({
  required UpdateArtifact artifact,
  required Directory stagingDir,
  required http.Client client,
  FreeSpace freeSpace = freeSpaceOf,
}) async {
  try {
    await stagingDir.create(recursive: true);
  } on FileSystemException catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.downloadFailed,
      'The update could not be saved to disk. Try again in a moment.',
      detail: '$error',
    );
  }
  final free = await freeSpace(stagingDir);
  if (free != null && free < artifact.size * 2) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.insufficientSpace,
      'There is not enough free disk space to download this update.',
      detail: 'need ${artifact.size * 2} bytes, have $free',
    );
  }
  final name = p.basename(artifact.url.path);
  final part = File(p.join(stagingDir.path, '$name.part'));
  await _fillPart(artifact, part, client);
  await _verifyOrDiscard(artifact, part);
  try {
    return await part.rename(p.join(stagingDir.path, name));
  } on FileSystemException catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.downloadFailed,
      'The update could not be saved to disk. Try again in a moment.',
      detail: '$error',
    );
  }
}

Future<void> _fillPart(
  UpdateArtifact artifact,
  File part,
  http.Client client,
) async {
  Object? last;
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    try {
      await _fetchFrom(artifact, part, client);
      return;
    } on SelfUpdateFailure {
      rethrow;
    } catch (error) {
      last = error;
    }
  }
  throw SelfUpdateFailure(
    SelfUpdateFailureKind.downloadFailed,
    'The update download was interrupted. Try again in a moment.',
    detail: '$last',
  );
}

Future<void> _fetchFrom(
  UpdateArtifact artifact,
  File part,
  http.Client client,
) async {
  var have = await part.exists() ? await part.length() : 0;
  if (have > artifact.size) {
    await part.delete();
    have = 0;
  }
  if (have == artifact.size) return;
  final request = http.Request('GET', artifact.url);
  if (have > 0) request.headers['Range'] = 'bytes=$have-';
  final response = await client.send(request);
  if (response.statusCode != 200 && response.statusCode != 206) {
    throw HttpException('status ${response.statusCode}', uri: artifact.url);
  }
  final resumed = response.statusCode == 206 && have > 0;
  final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
  var written = resumed ? have : 0;
  try {
    await for (final chunk in response.stream) {
      written += chunk.length;
      if (written > artifact.size) break;
      sink.add(chunk);
    }
  } finally {
    await sink.close();
  }
  if (written > artifact.size) {
    await part.delete();
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.sizeMismatch,
      'The downloaded update was larger than expected, so it was discarded.',
      detail: 'expected ${artifact.size} bytes, server sent more',
    );
  }
}

Future<void> _verifyOrDiscard(UpdateArtifact artifact, File part) async {
  final length = await part.length();
  if (length != artifact.size) {
    await part.delete();
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.sizeMismatch,
      'The downloaded update was not the expected size, so it was discarded.',
      detail: 'expected ${artifact.size} bytes, got $length',
    );
  }
  final sink = Sha256().newHashSink();
  await for (final chunk in part.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  final digest = (await sink.hash()).bytes;
  final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  if (hex != artifact.sha256) {
    await part.delete();
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.checksumMismatch,
      'The downloaded update did not match its checksum, so it was discarded.',
      detail: 'expected ${artifact.sha256}, got $hex',
    );
  }
}
