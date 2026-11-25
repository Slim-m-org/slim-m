// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The resync signal moves each time the connection goes live, and a durable
/// frame this client cannot read brings that about.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import '../support/sync_harness.dart';
import '../support/sync_live_rig.dart';

void main() {
  test('going live moves the signal, and an unreadable durable frame '
      'restarts the connection to move it again', () async {
    final rig = await SyncLiveRig.build(
      (r) =>
          r.on('POST', '/sync', (_) => jsonResponse({'scopes': <dynamic>[]})),
      seeded: [rigMessage('m1', 1, 'msg 1')],
      overrides: [
        syncControllerProvider.overrideWith(
          (ref) => SyncController(
            ref,
            backoffStep: const Duration(milliseconds: 20),
          ),
        ),
      ],
    );
    expect(rig.container.read(syncResyncProvider), 0);
    rig.signIn();
    await rig.waitFor(() => rig.status == SyncStatus.live);
    expect(rig.container.read(syncResyncProvider), 1);

    rig.server.pushEvent({
      'type': 'message.created',
      'message': <String, dynamic>{'id': 'm2'},
    });

    await rig.waitFor(
      () => rig.container.read(syncResyncProvider) == 2,
      reason: 'the unreadable frame never caused a reconnect',
    );
  });
}
