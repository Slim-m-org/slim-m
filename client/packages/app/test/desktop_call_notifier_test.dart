// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop call notifier turns an incoming DM ring into an OS
/// notification and takes it down when the ring ends.
///
/// Driven through the real [DmCallRingController] and real `CallRinging` /
/// `CallRingEnded` events rather than a stubbed ring, so this covers the
/// path a live socket actually takes - including the controller's own rule
/// that a ring you started yourself is not an incoming one.
///
/// The taking-down half is the one worth having. A call notification is
/// critical urgency, which on Linux means it does not time out on its own, so
/// a ring that was answered or swept would otherwise sit there claiming
/// someone is still calling.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/desktop_call_notifier.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';

class _FakeNotifications implements LocalNotifications {
  final shown = <LocalAlertChannel>[];
  final cancelled = <LocalAlertChannel>[];

  @override
  Future<void> show(String text, {required LocalAlertChannel channel}) async =>
      shown.add(channel);

  @override
  Future<void> cancel(LocalAlertChannel channel) async =>
      cancelled.add(channel);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  late StreamController<api.ServerEvent> events;
  late _FakeNotifications notifications;
  late ProviderContainer container;

  setUp(() {
    events = StreamController<api.ServerEvent>.broadcast();
    notifications = _FakeNotifications();
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        localNotificationsProvider.overrideWithValue(notifications),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(
              (_) async => http.Response(
                '[]',
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    container.read(desktopCallNotifierProvider);
    addTearDown(container.dispose);
    addTearDown(events.close);
  });

  /// One turn of the event loop, which is all a broadcast stream needs to
  /// deliver to the controller and the listener behind it.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> ring(String ringId, {String callerId = 'someone-else'}) async {
    events.add(
      api.CallRinging(channelId: 'c1', ringId: ringId, callerId: callerId),
    );
    await settle();
  }

  Future<void> endRing(String ringId) async {
    events.add(
      api.CallRingEnded(
        channelId: 'c1',
        ringId: ringId,
        outcome: api.CallOutcome.timedOut,
      ),
    );
    await settle();
  }

  test('an incoming ring raises one call notification', () async {
    expect(notifications.shown, isEmpty, reason: 'nothing before a ring');

    await ring('r1');

    expect(notifications.shown, [LocalAlertChannel.calls]);
  });

  test('the notification comes down when the ring ends', () async {
    await ring('r1');
    await endRing('r1');

    expect(notifications.cancelled, [LocalAlertChannel.calls]);
  });

  test('a ring this account started raises nothing', () async {
    await ring('r1', callerId: 'me');

    expect(notifications.shown, isEmpty);
  });

  test(
    'calls is the only channel allowed to interrupt, and Android owns it',
    () {
      expect(LocalAlertChannel.calls.critical, isTrue);
      expect(
        LocalAlertChannel.calls.androidOwnsThis,
        isTrue,
        reason:
            'IncomingCallNotifier.kt creates calls_v1 with CallStyle settings; '
            'creating it from Dart too would race it and fix the wrong ones',
      );
      for (final channel in LocalAlertChannel.values) {
        if (channel == LocalAlertChannel.calls) continue;
        expect(
          channel.critical,
          isFalse,
          reason: '${channel.name} must not be able to interrupt',
        );
      }
    },
  );
}
