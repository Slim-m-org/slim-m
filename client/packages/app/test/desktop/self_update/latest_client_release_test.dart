// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The update chip and the installer must agree on which release is on offer,
/// and neither may offer one whose signed manifest is not attached yet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_platform/platform.dart';

Map<String, dynamic> _release(
  String tag, {
  List<String> assets = const ['manifest.json', 'manifest.json.sig'],
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/x/y/releases/tag/$tag',
  'draft': false,
  'prerelease': false,
  'assets': [
    for (final name in assets) {'name': name},
  ],
};

// 9.9.9 is public but its manifest is not attached yet; 9.9.8 is complete.
MockClient _github(List<Map<String, dynamic>> releases) =>
    MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response(jsonEncode(releases), 200);
      }
      return http.Response('Not Found', 404);
    });

final _unfinished = [
  _release('client-v9.9.9', assets: const []),
  _release('client-v9.9.8'),
];

void main() {
  test(
    'the check skips a release whose manifest is not attached yet',
    () async {
      final update = await checkForClientUpdate(
        currentVersion: '9.9.0',
        client: _github(_unfinished),
        format: InstallFormat.tarball,
        failedVersion: '0.0.0',
      );
      expect(update?.version, '9.9.8');
    },
  );

  test(
    'the check offers nothing when the only newer release is unfinished',
    () {
      final releases = [
        _release('client-v9.9.9', assets: const ['manifest.json']),
      ];
      return expectLater(
        checkForClientUpdate(
          currentVersion: '9.9.0',
          client: _github(releases),
          format: InstallFormat.tarball,
          failedVersion: '0.0.0',
        ),
        completion(isNull),
      );
    },
  );

  test(
    'a suffixed tag is offered by neither the check nor the installer',
    () async {
      final releases = [_release('client-v9.9.9-rc.1')];
      final update = await checkForClientUpdate(
        currentVersion: '9.9.0',
        client: _github(releases),
        format: InstallFormat.tarball,
        failedVersion: '0.0.0',
      );
      expect(update, isNull);
    },
  );

  test('the installer falls back to the previous complete release', () async {
    final staging = Directory.systemTemp.createTempSync('slimm-latest-');
    addTearDown(() => staging.deleteSync(recursive: true));
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add(request.url.toString());
      if (request.url.host == 'api.github.com') {
        return http.Response(jsonEncode(_unfinished), 200);
      }
      return http.Response('Not Found', 404);
    });
    Object? thrown;
    try {
      await fetchVerifiedUpdate(
        currentVersion: '9.9.0',
        platformKey: 'linux-x64',
        stagingDir: staging,
        client: client,
      );
    } catch (error) {
      thrown = error;
    }
    expect(requested.any((u) => u.contains('client-v9.9.9')), isFalse);
    expect(
      requested.any((u) => u.contains('client-v9.9.8/manifest.json')),
      isTrue,
    );
    expect(thrown, isNotNull);
  });
}
