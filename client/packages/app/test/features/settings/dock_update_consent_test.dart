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

  group('platform powers', () {
    api.DockManifest platform({
      String? sha,
      List<String> events = const ['message.created'],
      Map<String, dynamic>? data,
    }) {
      final json = dockManifestJson(
        'digest',
        '0.2.0',
        capabilities: ['events', 'data.store', 'log.read'],
        extras: {'subscriptions': events, 'data': ?data},
      );
      if (sha != null) {
        (json['artifact'] as Map<String, dynamic>)['sha256'] = sha;
      }
      return api.DockManifest.fromJson(json);
    }

    final dataV1 = {
      'max_mb': 8,
      'tables': [
        {
          'name': 'xp',
          'columns': [
            {'name': 'user_id', 'type': 'text', 'unique': true},
          ],
        },
      ],
    };

    api.InstalledDockModule installed() => api.InstalledDockModule(
      id: 'digest',
      name: 'digest',
      version: '0.1.0',
      artifactSha256: _sha,
      approvedCapabilities: const ['events', 'data.store', 'log.read'],
      approvedHostCapabilities: const ['events', 'data.store', 'log.read'],
      extensionPoints: const [],
      enabled: true,
      installedAt: 1,
      subscriptions: const ['message.created'],
      dataSchema: api.dockDataSchema(dataV1),
    );

    test('the same build with the same reach asks for nothing', () {
      final manifest = platform(data: dataV1);
      expect(newConsentCapabilities(manifest, installed()), isEmpty);
      expect(dockConsentChanges(manifest, installed()), isEmpty);
    });

    test('a new build asks for events, data and log reading again', () {
      final manifest = platform(sha: _other, data: dataV1);
      expect(newConsentCapabilities(manifest, installed()), [
        'events',
        'data.store',
        'log.read',
      ]);
      expect(dockConsentChanges(manifest, installed()), [
        'This is a new build of the module code.',
      ]);
    });

    test('a new subscription asks for events and names it', () {
      final manifest = platform(
        events: const ['message.created', 'member.joined'],
        data: dataV1,
      );
      expect(newConsentCapabilities(manifest, installed()), ['events']);
      expect(dockConsentChanges(manifest, installed()), [
        'Now listens for member.joined.',
      ]);
    });

    test('a bigger cap, new table, new column or new index asks for data', () {
      Map<String, dynamic> withColumn(Map<String, dynamic> column) => {
        'max_mb': 8,
        'tables': [
          {
            'name': 'xp',
            'columns': [
              {'name': 'user_id', 'type': 'text', 'unique': true},
              column,
            ],
          },
        ],
      };
      final wider = <Map<String, dynamic>>[
        {...dataV1, 'max_mb': 16},
        {
          ...dataV1,
          'tables': [
            ...(dataV1['tables']! as List),
            {'name': 'log', 'columns': <Object>[]},
          ],
        },
        withColumn({'name': 'xp', 'type': 'int'}),
        {
          'max_mb': 8,
          'tables': [
            {
              'name': 'xp',
              'columns': [
                {
                  'name': 'user_id',
                  'type': 'text',
                  'unique': true,
                  'index': true,
                },
              ],
            },
          ],
        },
      ];
      for (final data in wider) {
        final manifest = platform(data: data);
        expect(newConsentCapabilities(manifest, installed()), ['data.store']);
        expect(dockConsentChanges(manifest, installed()), [
          'Now asks for more room in its data store.',
        ]);
      }
    });
  });
}
