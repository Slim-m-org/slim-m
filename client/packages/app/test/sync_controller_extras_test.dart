// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message caught up over `/sync` shows its file, not a blank row.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

import 'support/sync_harness.dart';
import 'support/sync_live_rig.dart';

const _sixGb = 6 * 1024 * 1024 * 1024;

Map<String, dynamic> _fileMessage() => {
  ...rigMessage('m-file', 1, ''),
  'attachments': [
    {
      'id': 'ab' * 32,
      'filename': 'backup.tar',
      'content_type': 'application/x-tar',
      'size': _sixGb,
    },
  ],
};

void main() {
  test('catch-up hands a synced message its attachments', () async {
    final rig = await SyncLiveRig.build(
      (router) => router.on(
        'POST',
        '/sync',
        (request) => jsonResponse({
          'scopes': [
            {
              'channel_id': 'c1',
              'messages': [_fileMessage()],
              'has_more': false,
              'reset': false,
            },
          ],
        }),
      ),
      seeded: const [],
    );
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');

    final extras = rig.container.read(messageExtrasProvider)['m-file'];
    expect(extras?.attachments.single.size, _sixGb);
  });
}
