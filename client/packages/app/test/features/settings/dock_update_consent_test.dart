// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An update that widens a power the admin already approved is asked about
/// again, and the sheet says what moved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_install_consent.dart';

import '../../dock_manifest_fixture.dart';

final _sha = List.filled(64, 'a').join();
final _other = List.filled(64, 'b').join();

api.DockManifest _manifest({
  String? sha,
  int every = 1440,
  List<String> hosts = const ['api.example.com'],
}) {
  final json = dockManifestJson(
    'digest',
    '0.2.0',
    capabilities: ['net.fetch', 'schedule', 'kv.store'],
    network: {'hosts': hosts, 'local': false},
    schedules: [
      {'command': 'post', 'every_minutes': every},
    ],
  );
  if (sha != null) (json['artifact'] as Map<String, dynamic>)['sha256'] = sha;
  return api.DockManifest.fromJson(json);
}

api.InstalledDockModule _installed({List<String>? approved}) =>
    api.InstalledDockModule(
      id: 'digest',
      name: 'digest',
      version: '0.1.0',
      artifactSha256: _sha,
      approvedCapabilities: const ['net.fetch', 'schedule', 'kv.store'],
      approvedHostCapabilities:
          approved ?? const ['net.fetch', 'schedule', 'kv.store'],
      extensionPoints: const [],
      enabled: true,
      installedAt: 1,
      networkHosts: const ['api.example.com'],
      schedules: const [api.DockSchedule(command: 'post', everyMinutes: 1440)],
    );

void main() {
  test('an unchanged update asks for nothing', () {
    expect(newConsentCapabilities(_manifest(), _installed()), isEmpty);
    expect(dockConsentChanges(_manifest(), _installed()), isEmpty);
  });

  test('a shorter schedule interval is asked about and said in words', () {
    final manifest = _manifest(every: 5);
    expect(newConsentCapabilities(manifest, _installed()), ['schedule']);
    expect(dockConsentChanges(manifest, _installed()), [
      'post now runs every 5 minutes, was every day.',
    ]);
  });

  test('a new build of a fetching or scheduled module is asked about', () {
    final manifest = _manifest(sha: _other);
    expect(newConsentCapabilities(manifest, _installed()), [
      'net.fetch',
      'schedule',
    ]);
    expect(dockConsentChanges(manifest, _installed()), [
      'This is a new build of the module code.',
    ]);
  });

  test('a new build of a module that was never approved to fetch is not', () {
    final manifest = _manifest(sha: _other);
    final plain = _installed(approved: const ['kv.store']);
    expect(newConsentCapabilities(manifest, plain), isEmpty);
    expect(dockConsentChanges(manifest, plain), isEmpty);
  });

  test('new hosts are named against the old ones', () {
    final manifest = _manifest(hosts: const ['api.example.com', 'evil.test']);
    expect(newConsentCapabilities(manifest, _installed()), ['net.fetch']);
    expect(dockConsentChanges(manifest, _installed()), [
      'Now reaches api.example.com, evil.test, was api.example.com.',
    ]);
  });
}
