// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/spotify/spotify_launch.dart';
import 'package:url_launcher/url_launcher.dart';

final _uri = Uri.https('accounts.spotify.com', '/authorize');

void main() {
  Future<(bool, List<LaunchMode>)> run({
    required bool phone,
    required Set<LaunchMode> accepts,
    bool throwOnApp = false,
  }) async {
    final modes = <LaunchMode>[];
    final ok = await openSpotifyAuthorize(
      _uri,
      phone: phone,
      opener: (uri, mode) async {
        modes.add(mode);
        if (throwOnApp && mode == LaunchMode.externalNonBrowserApplication) {
          throw StateError('no handler');
        }
        return accepts.contains(mode);
      },
    );
    return (ok, modes);
  }

  test('a phone with Spotify installed stays in the app', () async {
    final (ok, modes) = await run(
      phone: true,
      accepts: {LaunchMode.externalNonBrowserApplication},
    );
    expect(ok, isTrue);
    expect(modes, [LaunchMode.externalNonBrowserApplication]);
  });

  test('a phone without a claiming app falls back to the browser', () async {
    final (ok, modes) = await run(
      phone: true,
      accepts: {LaunchMode.externalApplication},
    );
    expect(ok, isTrue);
    expect(modes, [
      LaunchMode.externalNonBrowserApplication,
      LaunchMode.externalApplication,
    ]);
  });

  test('a failing app launch still falls back to the browser', () async {
    final (ok, modes) = await run(
      phone: true,
      accepts: {LaunchMode.externalApplication},
      throwOnApp: true,
    );
    expect(ok, isTrue);
    expect(modes.last, LaunchMode.externalApplication);
  });

  test('desktop and web go straight to the browser', () async {
    final (ok, modes) = await run(
      phone: false,
      accepts: {LaunchMode.externalApplication},
    );
    expect(ok, isTrue);
    expect(modes, [LaunchMode.externalApplication]);
  });
}
