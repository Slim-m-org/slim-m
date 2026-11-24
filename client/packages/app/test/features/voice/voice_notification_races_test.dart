// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A slow refresh or a failed save never overwrites a newer voice notification edit.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_notification_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

ProviderContainer _container(Future<http.Response> Function(http.Request) h) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      mockApiOverride(h),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'a refresh that was already in flight does not drop a newer edit',
    () async {
      final listing = Completer<http.Response>();
      final container = _container((request) {
        if (request.method == 'GET') return listing.future;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return Future.value(
          _json({'channel_id': request.url.pathSegments.last, ...body}),
        );
      });
      container.listen(voiceNotificationProvider, (_, _) {});
      await pumpEventQueue();
      final notifier = container.read(voiceNotificationProvider.notifier);

      await notifier.setStreams('lounge', streams: true);
      listing.complete(_json(<Object>[]));
      await pumpEventQueue();

      final state = container.read(voiceNotificationProvider);
      expect(state.forChannel('lounge').streams, isTrue);
    },
  );

  test('a failed save rolls back only its own channel', () async {
    final failing = Completer<http.Response>();
    final container = _container((request) {
      if (request.method == 'GET') return Future.value(_json(<Object>[]));
      if (request.url.pathSegments.last == 'a') return failing.future;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return Future.value(_json({'channel_id': 'b', ...body}));
    });
    container.listen(voiceNotificationProvider, (_, _) {});
    await pumpEventQueue();
    final notifier = container.read(voiceNotificationProvider.notifier);

    final saveA = notifier.setStreams('a', streams: true);
    final savingA = expectLater(saveA, throwsA(anything));
    await notifier.setStreams('b', streams: true);
    failing.complete(_json({'error': 'no'}, 500));
    await savingA;

    final state = container.read(voiceNotificationProvider);
    expect(state.forChannel('a').streams, isFalse);
    expect(state.forChannel('b').streams, isTrue);
  });
}
