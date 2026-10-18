// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the Dock shows about an installed module beyond its manifest, and the
/// module a member's command comes from.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('an installed module carries its run stats and storage when listed', () {
    final module = InstalledDockModule.fromJson({
      'id': 'digest',
      'name': 'Digest',
      'version': '0.1.0',
      'artifact_sha256': 'a',
      'approved_capabilities': <Object>[],
      'extension_points': <Object>[],
      'enabled': true,
      'installed_at': 1,
      'run_stats': [
        {
          'command': 'post',
          'run_count': 4,
          'failure_count': 2,
          'last_run_at': 50,
          'failing_since': 40,
          'last_error': 'module timed out',
          'last_duration_ms': 1000,
          'max_duration_ms': 1200,
        },
      ],
      'storage': {
        'entries': 3,
        'bytes': 24,
        'max_entries': 256,
        'max_bytes': 65536,
      },
    });
    final stat = module.runStats!.single;
    expect(stat.failingSince, 40);
    expect(stat.lastError, 'module timed out');
    expect(stat.lastOkAt, isNull);
    expect(module.storage!.entries, 3);
    expect(module.storage!.maxBytes, 65536);
  });

  test('a lifecycle answer without them leaves both null', () {
    final module = InstalledDockModule.fromJson({
      'id': 'digest',
      'name': 'Digest',
      'version': '0.1.0',
      'artifact_sha256': 'a',
      'approved_capabilities': <Object>[],
      'extension_points': <Object>[],
      'enabled': true,
      'installed_at': 1,
    });
    expect(module.runStats, isNull);
    expect(module.storage, isNull);
  });

  test('a slash command and an app name their module and its powers', () {
    final command = SlashCommand.fromJson({
      'module_id': 'weather',
      'command': 'now',
      'name': 'weather',
      'module': {
        'name': 'Weather',
        'verified': true,
        'capabilities': ['net.fetch', 'message.post'],
        'network_hosts': ['api.open-meteo.com'],
      },
    });
    expect(command.module!.name, 'Weather');
    expect(command.module!.reachesNetwork, isTrue);
    expect(command.module!.posts, isTrue);
    expect(command.module!.runsOnItsOwn, isFalse);
    expect(command.module!.networkHosts, ['api.open-meteo.com']);

    final older = App.fromJson({
      'module_id': 'life',
      'command': 'run',
      'name': 'Life',
    });
    expect(older.module, isNull);
  });

  test('a run that posted its output answers with the message id', () {
    final posted = RunModuleCommandResult.fromJson({
      'ok': true,
      'message_id': 'm1',
    });
    expect(posted.messageId, 'm1');
    expect(posted.output, isNull);
  });

  test('a manifest keeps the digest the install must echo', () {
    final manifest = DockManifest.fromJson({
      'id': 'dice',
      'name': 'Dice',
      'version': '0.1.3',
      'summary': 's',
      'artifact': {'kind': 'wasm', 'path': 'p', 'sha256': 'a'},
      'runtime': {
        'backend': 'wasm',
        'limits': <String, Object>{},
      },
      'permissions': <Object>[],
      'capabilities': <Object>[],
      'extension_points': <Object>[],
      'review_digest': 'abc123',
    });
    expect(manifest.reviewDigest, 'abc123');
  });

  test('the local dev source is marked local', () {
    final source = DockSource.fromJson({
      'id': 'dev',
      'repo': 'local/dev',
      'official': false,
      'local': true,
    });
    expect(source.local, isTrue);
  });
}
