// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one rule for which `client-v*` release is on offer, shared by the
/// update chip and the installer so the chip never offers what install()
/// cannot fetch.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../update_check.dart' show isNewer;
import 'update_manifest.dart' show isPlainVersion;

const _tagPrefix = 'client-v';

/// A published client release that is finished: plain version, signed manifest attached.
class ClientRelease {
  const ClientRelease({
    required this.tag,
    required this.version,
    required this.htmlUrl,
  });

  final String tag;
  final String version;
  final String? htmlUrl;
}

/// The newest finished release in a GitHub `releases` list, or null.
///
/// The signed manifest is attached last, after the release is already public,
/// so a release without it is skipped and the previous complete one still wins.
ClientRelease? latestClientRelease(List<dynamic> releases) {
  ClientRelease? best;
  for (final entry in releases) {
    final candidate = _finishedRelease(entry);
    if (candidate == null) continue;
    if (best != null && !isNewer(candidate.version, best.version)) continue;
    best = candidate;
  }
  return best;
}

ClientRelease? _finishedRelease(Object? entry) {
  if (entry is! Map<String, dynamic>) return null;
  if (entry['draft'] == true || entry['prerelease'] == true) return null;
  final tag = entry['tag_name'];
  if (tag is! String || !tag.startsWith(_tagPrefix)) return null;
  final version = tag.substring(_tagPrefix.length);
  if (!isPlainVersion(version) || !_hasSignedManifest(entry['assets'])) {
    return null;
  }
  final url = entry['html_url'];
  return ClientRelease(
    tag: tag,
    version: version,
    htmlUrl: url is String ? url : null,
  );
}

bool _hasSignedManifest(Object? assets) {
  if (assets is! List) return false;
  final names = {
    for (final asset in assets)
      if (asset is Map<String, dynamic>) asset['name'],
  };
  return names.contains('manifest.json') && names.contains('manifest.json.sig');
}

/// How long a release found by the check may stand in for a second lookup.
const recentReleaseMaxAge = Duration(minutes: 10);

ClientRelease? _recent;
DateTime? _recentAt;

/// Remembers [release], so the install that follows the check skips a second
/// call against GitHub's 60 requests an hour limit.
void rememberLatestClientRelease(ClientRelease release, {DateTime? now}) {
  _recent = release;
  _recentAt = now ?? DateTime.now();
}

/// The release the check found within [recentReleaseMaxAge], or null.
ClientRelease? recentLatestClientRelease({DateTime? now}) {
  final at = _recentAt;
  if (at == null) return null;
  final age = (now ?? DateTime.now()).difference(at);
  return age < recentReleaseMaxAge ? _recent : null;
}

@visibleForTesting
void forgetLatestClientRelease() {
  _recent = null;
  _recentAt = null;
}
