// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A host-run connector's wire fields (decision 0134): the manifest's ask, the
/// approval the install sends, and the state and log lines admins read.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _image = 'ghcr.io/slim-m-org/jellyfin@sha256:0123';

Map<String, dynamic> _manifest(Map<String, dynamic> connector) => {
      'id': 'jellyfin',
      'name': 'Jellyfin',
      'version': '0.1.0',
      'summary': 's',
      'artifact': {'kind': 'connector', 'path': '', 'sha256': ''},
      'runtime': {'backend': 'connector', 'limits': <String, Object>{}},
      'permissions': <Object>[],
      'capabilities': <Object>[],
      'extension_points': <Object>[],
      'provider': 'connector',
      'connector': connector,
    };

void main() {
  test('a host-run ask carries its image, egress and limits', () {
    final m = DockManifest.fromJson(_manifest({
      'permissions': 6,
      'host_run': {
        'image': _image,
        'egress': [
          {'host': 'jellyfin.lan', 'port': 8096},
        ],
        'egress_private': true,
        'volume': true,
        'limits': {'memory_mib': 64, 'cpus': 1},
      },
    }));
    final ask = m.hostRun!;
    expect(ask.image, _image);
    expect(
        ask.egress.single, const EgressHost(host: 'jellyfin.lan', port: 8096));
    expect(ask.egressPrivate, isTrue);
    expect(ask.volume, isTrue);
    expect((ask.memoryMib, ask.cpus, ask.pids), (64, 1.0, null));
  });

  test('an admin-started connector has no host-run ask', () {
    expect(
        DockManifest.fromJson(_manifest({'permissions': 6})).hostRun, isNull);
  });

  test('the approval sends only what was approved', () {
    const approval = HostRunApproval(
      egress: [EgressHost(host: 'jellyfin.lan', port: 8096)],
    );
    expect(approval.toJson(), {
      'egress': [
        {'host': 'jellyfin.lan', 'port': 8096},
      ],
      'egress_private': false,
    });
  });

  test('a status parses every state and keeps an unknown one apart', () {
    final status = ConnectorHostRun.fromJson({
      'state': 'disabled_after_crashes',
      'image': _image,
      'egress': <Object>[],
      'egress_private': false,
      'volume': false,
      'limits': <String, Object>{},
      'oom_killed': true,
      'restarts': 5,
      'exit_code': 137,
      'last_error': 'Turned off after 5 crashes within 10 minutes.',
    });
    expect(status.state, HostRunState.disabledAfterCrashes);
    expect(
        (status.restarts, status.exitCode, status.oomKilled), (5, 137, true));
    expect(HostRunState.parse('runtime_unavailable'),
        HostRunState.runtimeUnavailable);
    expect(HostRunState.parse('something_new'), HostRunState.unknown);
  });

  test('the runtime status and log lines parse', () {
    final runtime = ConnectorRuntimeStatus.fromJson(
        {'configured': true, 'available': false, 'detail': 'down'});
    expect((runtime.configured, runtime.available, runtime.detail),
        (true, false, 'down'));
    final line = HostRunLogLine.fromJson(
        {'ts': '2026-11-22T10:00:00Z', 'stream': 'stderr', 'text': 'oops'});
    expect((line.stream, line.text), ('stderr', 'oops'));
  });
}
