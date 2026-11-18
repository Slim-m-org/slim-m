// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An open thread's parent card follows a live edit or delete of the parent
/// message, rather than showing its old text until the thread is reopened.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../support/fake_api.dart';

void main() {
  test('a parent deleted while its thread is open reads as deleted', () async {
    var deleted = false;
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [
        liveEventsProvider.overrideWithValue(events.stream),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 99999999999999,
            ),
          ),
        ),
        mockApiOverride(
          (request) async => http.Response(
            jsonEncode({
              'parent_channel_id': 'c1',
              'parent_message_id': 'p1',
              'parent_deleted': deleted,
              if (!deleted) 'parent_content': 'the question',
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(threadParentProvider('t1'), (_, _) {});
    addTearDown(sub.close);

    expect(
      (await container.read(threadParentProvider('t1').future)).parentDeleted,
      isFalse,
    );

    deleted = true;
    events.add(const api.MessageDeleted(channelId: 'c1', messageId: 'p1'));
    await pumpEventQueue();

    expect(
      (await container.read(threadParentProvider('t1').future)).parentDeleted,
      isTrue,
    );
  });
}
