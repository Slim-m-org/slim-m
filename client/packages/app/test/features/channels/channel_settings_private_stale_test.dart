// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Private toggle gives up its tapped value once the stored one agrees,
/// even when the channel update beat the write's own reply.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/widgets/channel_settings_private_row.dart';
import 'package:slimm_app/src/permissions.dart';

import '../../support/async_wait.dart';
import 'channel_management_harness.dart' show channel;
import 'channel_row_scope.dart';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('a channel update that lands before the write ends still '
      'retires the tapped value', (tester) async {
    final gate = Completer<void>();
    await tester.pumpWidget(
      channelRowScope(ChannelPrivateRow(channel: channel('c1', 'general')), (
        request,
      ) async {
        final path = request.url.path;
        if (path == '/roles') {
          return _json([
            {
              'id': 'everyone',
              'name': 'everyone',
              'permissions': Perm.viewChannel,
              'is_everyone': true,
              'created_at': 0,
            },
          ]);
        }
        if (request.method == 'DELETE') {
          await gate.future;
          return http.Response('', 204);
        }
        if (path == '/channels/c1/overwrites') {
          return _json({
            'overwrites': [
              {
                'kind': 'role',
                'id': 'everyone',
                'allow': 0,
                'deny': Perm.viewChannel,
              },
            ],
            'synced': false,
          });
        }
        return http.Response('{}', 200);
      }),
    );
    final store = await storeBehind(tester, find.text('Private'));
    await emitChannel(tester, store, restricted: true);
    final toggle = find.bySemanticsLabel('Private channel');
    expect(tester.getSemantics(toggle), isSemantics(isToggled: true));

    await tester.tap(toggle);
    await pumpFrames(tester);
    await emitChannel(tester, store, restricted: false);
    gate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await pumpFrames(tester);
    await emitChannel(tester, store, restricted: true);

    expect(
      tester.getSemantics(toggle),
      isSemantics(isToggled: true),
      reason: 'a later change elsewhere shows, not the old tapped value',
    );
    await unmountRow(tester);
  });
}
