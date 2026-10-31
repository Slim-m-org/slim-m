// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tapping a push notification opens the channel it came from.
///
/// Reported from real device use as "clicking on a notification takes me to
/// the channel page but I have no idea where that message came from". It
/// never took anyone anywhere: nothing listened for a tap, so the app resumed
/// to whatever route it was last on.
///
/// Both delivery paths are driven, because neither covers the other: a tap on
/// a running app arrives on the stream, and the tap that launched a killed app
/// is held natively and answered once when asked. The iOS half of this cannot
/// be run anywhere in this project, so what is pinned here is every decision
/// made on the Dart side of that channel.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/push/providers/notification_tap_router.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_platform/platform.dart';

/// A tap source with no platform channel under it, so the provider's own
/// wiring is what is under test rather than the method-channel plumbing
/// `packages/platform`'s own test already covers.
class _FakeTaps implements NotificationTapChannel {
  _FakeTaps({this.initial});

  final String? initial;
  final _controller = StreamController<String>.broadcast();
  var initialTaken = 0;

  @override
  Stream<String> get taps => _controller.stream;

  @override
  Future<String?> takeInitial() async {
    initialTaken++;
    return initial;
  }

  @override
  Future<void> dispose() => _controller.close();

  void emit(String channelId) => _controller.add(channelId);
}

GoRouter _router() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, __) => const Placeholder()),
    GoRoute(
      path: Routes.channelPattern,
      builder: (_, __) => const Placeholder(),
    ),
  ],
);

String _where(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

ProviderContainer _container(GoRouter router, _FakeTaps taps) {
  final container = ProviderContainer(
    overrides: [
      routerProvider.overrideWithValue(router),
      notificationTapChannelProvider.overrideWithValue(taps),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The router only reports where it is once its delegate is actually driving
/// something, so every case here runs against a real mounted router rather
/// than a bare `GoRouter` whose location would read empty whatever happened.
Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container,
  GoRouter router,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('channelRouteForTap', () {
    test('a channel id becomes that channel, opened for its chat', () {
      expect(channelRouteForTap('abc'), Routes.channel('abc', openChat: true));
      expect(channelRouteForTap('abc'), '/channels/abc?chat=1');
      expect(Routes.opensChat(Uri.parse(channelRouteForTap('abc')!)), isTrue);
      expect(Routes.opensChat(Uri.parse(Routes.channel('abc'))), isFalse);
    });

    test('nothing usable is no destination', () {
      expect(channelRouteForTap(null), isNull);
      expect(channelRouteForTap(''), isNull);
    });
  });

  testWidgets('a tap while running opens that channel', (tester) async {
    final router = _router();
    final taps = _FakeTaps();
    final container = _container(router, taps);
    container.read(notificationTapRouterProvider);
    await _mount(tester, container, router);

    taps.emit('channel-1');
    await tester.pumpAndSettle();

    expect(_where(router), Routes.channel('channel-1', openChat: true));
  });

  testWidgets('the tap that launched the app opens that channel', (
    tester,
  ) async {
    final router = _router();
    final taps = _FakeTaps(initial: 'channel-2');
    final container = _container(router, taps);
    container.read(notificationTapRouterProvider);
    await _mount(tester, container, router);

    expect(
      _where(router),
      Routes.channel('channel-2', openChat: true),
      reason:
          'a tap is how a killed app is usually launched, so the one '
          'held natively has to move the app too',
    );
    expect(taps.initialTaken, 1);
  });

  testWidgets('no tap leaves the app where it was', (tester) async {
    final router = _router();
    final taps = _FakeTaps();
    final container = _container(router, taps);
    container.read(notificationTapRouterProvider);
    await _mount(tester, container, router);

    expect(
      _where(router),
      '/',
      reason:
          'an ordinary launch must not be routed anywhere; without this '
          'the other tests would pass with the provider navigating blindly',
    );
  });

  testWidgets('a tap after disposal is not routed', (tester) async {
    final router = _router();
    final taps = _FakeTaps();
    final container = _container(router, taps);
    container.read(notificationTapRouterProvider);
    await _mount(tester, container, router);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    taps.emit('channel-3');
    await tester.pump();

    expect(_where(router), '/');
  });
}
