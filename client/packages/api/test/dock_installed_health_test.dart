// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The health fields an installed module carries: the breaker's reason, the
/// failure streak and the dropped events, defaulting to a healthy module.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _installed([Map<String, dynamic> extra = const {}]) => {
      'id': 'xp',
      'name': 'xp',
      'version': '1.0.0',
      'artifact_sha256': 'a' * 64,
      'approved_capabilities': <String>[],
      'extension_points': <Object>[],
      'enabled': false,
      'installed_at': 1,
      ...extra,
    };

void main() {
  test('health fields are read', () {
    final m = InstalledDockModule.fromJson(_installed({
      'consecutive_failures': 5,
      'disabled_reason': 'Failed 5 runs in a row.',
      'events_dropped': 3,
    }));
    expect(m.consecutiveFailures, 5);
    expect(m.disabledReason, 'Failed 5 runs in a row.');
    expect(m.eventsDropped, 3);
  });

  test('a body without them is healthy', () {
    final m = InstalledDockModule.fromJson(_installed());
    expect(m.consecutiveFailures, 0);
    expect(m.disabledReason, isNull);
    expect(m.eventsDropped, 0);
  });

  test('subscriptions and the data schema are read', () {
    final m = InstalledDockModule.fromJson(_installed({
      'subscriptions': [
        'message.created',
        {'event': 'member.joined'}
      ],
      'data': {
        'max_mb': 4,
        'tables': [
          {
            'name': 'xp',
            'columns': [
              {'name': 'user_id', 'type': 'text', 'unique': true},
            ],
          },
        ],
      },
    }));
    expect(m.subscriptions, ['message.created', 'member.joined']);
    expect(m.dataSchema!.maxMb, 4);
    expect(m.dataSchema!.tables['xp']!['user_id']!.unique, isTrue);
  });
}
