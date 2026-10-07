// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Checks GitHub for a newer client release, so the startup screen can offer
/// it, and `update_watch.dart` can offer it again on a timer for a session
/// that never revisits the splash. Phase 1 of decision 0020: this only ever
/// reports what it found, with a format-appropriate action the UI turns into
/// a link or a package-manager hint - nothing is downloaded or executed here.
///
/// Best-effort by construction: a network failure, a timeout, a rate-limit,
/// or any unexpected shape resolves to `null` (no update to offer), never an
/// error and never a block on startup.
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:slimm_platform/platform.dart';

import 'self_update/latest_client_release.dart';
import 'self_update/self_update_target.dart' show recordedFailedVersion;

/// The repository whose `client-v*` releases this build updates from.
const clientReleaseRepo = 'Slim-m-org/slim-m';

/// Whether the update check is switched off by `SLIMM_NO_UPDATE_CHECK`. Honors
/// AppImage's golden rule that an app respect a "do not check for updates"
/// flag - a system may manage updates centrally - and lets the desktop-shell
/// smoke and any offline CI run the real startup path without the check ever
/// reaching out or, worse, blocking on a prompt with no one to answer it.
bool updateChecksDisabled() {
  if (kIsWeb) return false;
  final flag = Platform.environment['SLIMM_NO_UPDATE_CHECK'];
  return flag != null &&
      flag.isNotEmpty &&
      flag != '0' &&
      flag.toLowerCase() != 'false';
}

/// How long the release check may take before startup gives up and launches
/// the current client regardless.
const _timeout = Duration(seconds: 4);

/// A newer client release than the one running, and how this install can get
/// it.
class ClientUpdate {
  const ClientUpdate({
    required this.version,
    required this.releaseUrl,
    required this.format,
  });

  /// The newer version, without the `client-v` tag prefix (for example
  /// `0.70.0`).
  final String version;

  /// The release's GitHub page, where every format's artifacts are attached.
  final String releaseUrl;

  /// How this build was installed, which decides the action the UI offers.
  final InstallFormat format;
}

/// [checkForClientUpdate]'s own shape, so a caller can inject a fake without
/// reaching for a fake HTTP client to express "there is nothing newer".
typedef CheckForClientUpdate =
    Future<ClientUpdate?> Function({
      required String currentVersion,
      http.Client? client,
      InstallFormat? format,
    });

/// The latest `client-v*` release newer than [currentVersion], or `null` when
/// there is none, the check failed, [currentVersion] cannot be read, or this
/// is not a self-updatable desktop build's concern. [client] and [format] are
/// injectable for tests.
///
/// A release at or below the version a rollback last went back from is never
/// offered: it already failed to start here. [failedVersion] defaults to the
/// record of the running install.
Future<ClientUpdate?> checkForClientUpdate({
  required String currentVersion,
  http.Client? client,
  InstallFormat? format,
  String? failedVersion,
}) async {
  final installFormat = format ?? currentInstallFormat();
  if (installFormat == InstallFormat.unknown) return null;

  final owned = client ?? http.Client();
  try {
    final response = await owned
        .get(
          Uri.parse(
            'https://api.github.com/repos/$clientReleaseRepo/releases?per_page=30',
          ),
          headers: const {'Accept': 'application/vnd.github+json'},
        )
        .timeout(_timeout);
    if (response.statusCode != 200) return null;
    final releases = jsonDecode(response.body);
    if (releases is! List) return null;

    final best = latestClientRelease(releases);
    final bestVersion = best?.version;
    final bestUrl = best?.htmlUrl;
    if (bestVersion == null || bestUrl == null) return null;
    if (!isNewer(bestVersion, currentVersion)) return null;
    final failed = failedVersion ?? recordedFailedVersion();
    if (failed != null && !isNewer(bestVersion, failed)) return null;
    return ClientUpdate(
      version: bestVersion,
      releaseUrl: bestUrl,
      format: installFormat,
    );
  } catch (_) {
    return null;
  } finally {
    if (client == null) owned.close();
  }
}

/// Where the version last dismissed with "Not now" is stored.
const dismissedUpdateVersionKey = 'slimm.update.dismissed_version';

/// Whether an offer of [candidate] should be withheld because the user already
/// said "Not now" to [dismissed].
///
/// Phase 1 cannot apply an update itself: an rpm or flatpak has to be updated
/// out-of-band, which can be days later. Re-offering the same version on every
/// launch until then is the whole of "I keep getting the update screen", so a
/// dismissal holds until something genuinely newer than it exists.
bool updateWasDismissed({
  required String? dismissed,
  required String candidate,
}) => dismissed != null && !isNewer(candidate, dismissed);

/// `[major, minor, patch]` from a `X.Y.Z` string, or `null` if it is not that
/// shape. Any pre-release or build suffix after the patch is ignored.
List<int>? parseVersion(String raw) {
  final core = raw.split(RegExp('[-+]')).first;
  final parts = core.split('.');
  if (parts.length != 3) return null;
  final numbers = <int>[];
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null) return null;
    numbers.add(n);
  }
  return numbers;
}

/// Whether [candidate] is a strictly higher version than [against].
///
/// Either side failing to parse answers false, because the honest answer is
/// "cannot tell" and the only safe reading of that here is "do not offer".
/// [against] used to answer true, which meant an install whose own version
/// could not be read - `PackageInfo` returns an empty string on Linux when
/// `version.json` is not where it expects it - was told that every release
/// ever published was newer than it, on every single launch.
bool isNewer(String candidate, String against) {
  final a = parseVersion(candidate);
  final b = parseVersion(against);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}
