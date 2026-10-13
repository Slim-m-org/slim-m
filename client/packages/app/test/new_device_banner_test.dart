// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The warning shown when another device signs into this account: it appears
/// on the live frame, "This wasn't me" opens the devices pane, and it is
/// gone for a dismissal. Also the PNGs for looking at it under
/// SLIMM_UI_SNAPSHOTS=1, light and dark, phone and desktop.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/new_device_banner_host.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

const _signIn = NewDeviceSignIn(
  deviceId: 'd2',
  deviceName: 'Ada laptop',
  clientKind: 'desktop',
  signedInAt: 1700000000000,
);

class _Harness {
  _Harness(this.events, this.router);

  final StreamController<ServerEvent> events;
  final GoRouter router;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final events = StreamController<ServerEvent>.broadcast();
  addTearDown(events.close);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => NewDeviceBannerHost(
          child: const Scaffold(body: Center(child: Text('shell'))),
        ),
      ),
      GoRoute(
        path: Routes.personalSettings,
        builder: (context, state) => Text(
          'settings pane ${state.uri.queryParameters[settingsPaneQuery]}',
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness,
            brightness == Brightness.light ? AppTokens.light : AppTokens.dark,
          ),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(events, router);
}

/// The frame reaches the provider a microtask after `add`, so it needs a second pump to paint.
Future<void> _emit(WidgetTester tester, _Harness harness) async {
  harness.events.add(_signIn);
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('nothing shows until a device signs in', (tester) async {
    await _pump(tester);
    expect(find.byType(NewDeviceSignInBanner), findsNothing);
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('a live frame shows the device and "This wasn\'t me" opens '
      'the devices pane', (tester) async {
    final harness = await _pump(tester);
    await _emit(tester, harness);

    expect(find.textContaining('Ada laptop (desktop)'), findsOneWidget);
    await tester.tap(find.text("This wasn't me"));
    await tester.pumpAndSettle();

    expect(find.text('settings pane $accountDevicesPane'), findsOneWidget);
    harness.router.go('/');
    await tester.pumpAndSettle();
    expect(find.byType(NewDeviceSignInBanner), findsNothing);
  });

  testWidgets('"This was me" dismisses it without navigating', (tester) async {
    final harness = await _pump(tester);
    await _emit(tester, harness);

    await tester.tap(find.text('This was me'));
    await tester.pump();

    expect(find.byType(NewDeviceSignInBanner), findsNothing);
    expect(find.text('shell'), findsOneWidget);
  });

  group('the sign-in time reads as the rest of the app does', () {
    final signedIn = DateTime(2026, 9, 30, 21, 25).millisecondsSinceEpoch;
    final now = DateTime(2026, 9, 30, 21, 40);

    test('today, yesterday and an older day follow the transcript wording', () {
      expect(
        signInWhen(signedIn, use24Hour: false, now: now),
        'today at 9:25\u00A0PM',
      );
      expect(signInWhen(signedIn, use24Hour: true, now: now), 'today at 21:25');
      expect(
        signInWhen(signedIn, use24Hour: false, now: DateTime(2026, 10, 1)),
        'yesterday at 9:25\u00A0PM',
      );
      expect(
        signInWhen(signedIn, use24Hour: false, now: DateTime(2026, 11, 3)),
        'on September 30 at 9:25\u00A0PM',
      );
    });
  });

  testWidgets('at phone width the banner shows no ISO date and keeps the '
      'time on one line', (tester) async {
    final harness = await _pump(tester);
    await _emit(tester, harness);

    final line = find.textContaining('New sign-in:');
    final text = tester.widget<Text>(line).textSpan!.toPlainText();
    expect(text, isNot(matches(RegExp(r'\d{4}-\d{2}-\d{2}'))));
    final time = RegExp(r'\d{1,2}:\d{2}\u00A0[AP]M').firstMatch(text)!;

    final paragraph = tester.renderObject<RenderParagraph>(line);
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: time.start, extentOffset: time.end),
    );
    expect(
      boxes,
      hasLength(1),
      reason: 'the clock time wraps across two lines: $text',
    );
  });

  testWidgets('in dark the banner sits on the theme surface, not on the bare '
      'window behind it', (tester) async {
    final harness = await _pump(tester, brightness: Brightness.dark);
    await _emit(tester, harness);

    final backdrop = tester
        .widgetList<Material>(
          find.ancestor(
            of: find.byType(NewDeviceSignInBanner),
            matching: find.byType(Material),
          ),
        )
        .first;

    expect(backdrop.color, AppTokens.dark.surfaceBase);
  });

  const viewports = {'phone': Size(390, 844), 'desktop': Size(1400, 880)};
  for (final viewport in viewports.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('banner at ${viewport.key} ${brightness.name} fits', (
        tester,
      ) async {
        final harness = await _pump(
          tester,
          size: viewport.value,
          brightness: brightness,
        );
        await _emit(tester, harness);

        final name = 'new-device-banner-${viewport.key}-${brightness.name}';
        await expectSettled(tester, name);
        await writeSnapshot(tester, name);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final (width, inline) in [(1280.0, true), (390.0, false)]) {
    testWidgets('at ${width.toInt()} wide the answers sit '
        '${inline ? 'beside' : 'under'} the message', (tester) async {
      tester.view.physicalSize = Size(width, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: NewDeviceSignInBanner(alert: _signIn),
              ),
            ),
          ),
        ),
      );
      final message = tester.getRect(find.textContaining('New sign-in:'));
      final answer = tester.getRect(find.text("This wasn't me"));
      if (inline) {
        expect(answer.left, greaterThan(message.right));
        expect(answer.top, lessThan(message.bottom));
      } else {
        expect(answer.top, greaterThanOrEqualTo(message.bottom));
      }
    });
  }
}
