// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one rule for which `client-v*` release is on offer, shared by the
/// update chip and the installer so the chip never offers what install()
/// cannot fetch.
library;

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
    if (entry is! Map<String, dynamic>) continue;
    if (entry['draft'] == true || entry['prerelease'] == true) continue;
    final tag = entry['tag_name'];
    if (tag is! String || !tag.startsWith(_tagPrefix)) continue;
    final version = tag.substring(_tagPrefix.length);
    if (!isPlainVersion(version) || !_hasSignedManifest(entry['assets'])) {
      continue;
    }
    if (best != null && !isNewer(version, best.version)) continue;
    final url = entry['html_url'];
    best = ClientRelease(
      tag: tag,
      version: version,
      htmlUrl: url is String ? url : null,
    );
  }
  return best;
}

bool _hasSignedManifest(Object? assets) {
  if (assets is! List) return false;
  final names = {
    for (final asset in assets)
      if (asset is Map<String, dynamic>) asset['name'],
  };
  return names.contains('manifest.json') && names.contains('manifest.json.sig');
}
