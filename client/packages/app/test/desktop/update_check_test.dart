// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_platform/platform.dart';

http.Client releasing(List<Map<String, dynamic>> releases) =>
    MockClient((_) async => http.Response(jsonEncode(releases), 200));

Map<String, dynamic> rel(
  String tag, {
  bool draft = false,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/Slim-m-org/slim-m/releases/tag/$tag',
  'draft': draft,
  'prerelease': prerelease,
  'assets': [
    {'name': 'manifest.json'},
    {'name': 'manifest.json.sig'},
  ],
};

void main() {
  group('version comparison', () {
    test('parses and rejects', () {
      expect(parseVersion('0.69.0'), [0, 69, 0]);
      expect(parseVersion('1.2.3-rc1'), [1, 2, 3]);
      expect(parseVersion('1.2'), isNull);
      expect(parseVersion('x.y.z'), isNull);
    });

    test('orders by major, minor, patch', () {
      expect(isNewer('0.70.0', '0.69.0'), isTrue);
      expect(isNewer('0.69.1', '0.69.0'), isTrue);
      expect(isNewer('1.0.0', '0.99.99'), isTrue);
      expect(isNewer('0.69.0', '0.69.0'), isFalse);
      expect(isNewer('0.68.0', '0.69.0'), isFalse);
    });

    /// A version that will not parse means "cannot tell", and the only safe
    /// reading of that is "not newer". The right-hand side used to answer
    /// true, which is what made a build with an unreadable version.json offer
    /// an update on every launch forever.
    test('an unreadable version on either side is not newer', () {
      expect(isNewer('0.70.0', ''), isFalse);
      expect(isNewer('0.70.0', 'unknown'), isFalse);
      expect(isNewer('', '0.70.0'), isFalse);
    });
  });

  group('a dismissed offer', () {
    test('stays dismissed until something newer exists', () {
      expect(
        updateWasDismissed(dismissed: '0.73.0', candidate: '0.73.0'),
        isTrue,
        reason: 'the same version must not be offered again next launch',
      );
      expect(
        updateWasDismissed(dismissed: '0.73.0', candidate: '0.74.0'),
        isFalse,
        reason: 'a genuinely newer release is worth asking about again',
      );
      expect(
        updateWasDismissed(dismissed: '0.73.0', candidate: '0.72.0'),
        isTrue,
      );
    });

    test('nothing dismissed suppresses nothing', () {
      expect(updateWasDismissed(dismissed: null, candidate: '0.73.0'), isFalse);
    });
  });

  group('checkForClientUpdate', () {
    test(
      'offers the highest client-v release newer than the running one',
      () async {
        final client = releasing([
          rel('server-v0.60.0'),
          rel('client-v0.70.0'),
          rel('client-v0.69.0'),
        ]);
        final update = await checkForClientUpdate(
          currentVersion: '0.69.0',
          client: client,
          format: InstallFormat.tarball,
        );
        expect(update, isNotNull);
        expect(update!.version, '0.70.0');
        expect(update.format, InstallFormat.tarball);
        expect(update.releaseUrl, contains('client-v0.70.0'));
      },
    );

    test('returns null when the newest client release is not newer', () async {
      final client = releasing([rel('client-v0.69.0'), rel('client-v0.68.0')]);
      expect(
        await checkForClientUpdate(
          currentVersion: '0.69.0',
          client: client,
          format: InstallFormat.rpm,
        ),
        isNull,
      );
    });

    test('ignores drafts, prereleases, and non-client tags', () async {
      final client = releasing([
        rel('client-v0.71.0', draft: true),
        rel('client-v0.72.0', prerelease: true),
        rel('server-v9.9.9'),
        rel('client-v0.70.0'),
      ]);
      final update = await checkForClientUpdate(
        currentVersion: '0.69.0',
        client: client,
        format: InstallFormat.appImage,
      );
      expect(update!.version, '0.70.0');
    });

    test(
      'a non-200, bad body, or network error is no update, never a throw',
      () async {
        final err = MockClient((_) async => http.Response('nope', 503));
        expect(
          await checkForClientUpdate(
            currentVersion: '0.69.0',
            client: err,
            format: InstallFormat.tarball,
          ),
          isNull,
        );
        final junk = MockClient((_) async => http.Response('not json', 200));
        expect(
          await checkForClientUpdate(
            currentVersion: '0.69.0',
            client: junk,
            format: InstallFormat.tarball,
          ),
          isNull,
        );
      },
    );

    /// The reported bug: on Linux `PackageInfo` answers with an empty string
    /// when it cannot find `version.json` beside the executable, and the check
    /// then treated every published release as newer than the running build.
    test(
      'a build that cannot read its own version is never offered one',
      () async {
        final client = releasing([
          rel('client-v0.73.0'),
          rel('client-v0.72.0'),
        ]);
        expect(
          await checkForClientUpdate(
            currentVersion: '',
            client: client,
            format: InstallFormat.rpm,
          ),
          isNull,
        );
      },
    );

    test('an unknown install format never checks', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('[]', 200);
      });
      final update = await checkForClientUpdate(
        currentVersion: '0.69.0',
        client: client,
        format: InstallFormat.unknown,
      );
      expect(update, isNull);
      expect(called, isFalse);
    });
  });

  group('an android build', () {
    test('is told about a newer client release', () async {
      final update = await checkForClientUpdate(
        currentVersion: '0.1.0',
        client: releasing([rel('client-v9.9.9')]),
        format: InstallFormat.apk,
        failedVersion: '0.0.0',
      );

      expect(update?.version, '9.9.9');
      expect(update?.format, InstallFormat.apk);
    });

    test('is told nothing when it is already current', () async {
      final update = await checkForClientUpdate(
        currentVersion: '9.9.9',
        client: releasing([rel('client-v9.9.9')]),
        format: InstallFormat.apk,
        failedVersion: '0.0.0',
      );

      expect(update, isNull);
    });
  });

  test('a host with no known packaging is still told nothing', () async {
    final update = await checkForClientUpdate(
      currentVersion: '0.1.0',
      client: releasing([rel('client-v9.9.9')]),
      format: InstallFormat.unknown,
      failedVersion: '0.0.0',
    );

    expect(update, isNull);
  });
}
