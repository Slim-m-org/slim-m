// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// iOS ignores badge writes while Badges is off, so Notifications says so.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_app/src/providers/app_badge_sync.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/mid_flight_capture.dart';

const _channel = MethodChannel('top.npcserver.slimm/app_badge');

Future<void> _open(WidgetTester tester, {required bool allowed}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async => allowed);
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        appBadgeChannelProvider.overrideWithValue(AppBadgeChannel(isIOS: true)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: NotificationsSection(hasPushChannel: false),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await expectSettled(tester, 'notifications badges');
}

void main() {
  testWidgets('says Badges is off when iOS has it disabled', (tester) async {
    await _open(tester, allowed: false);
    expect(find.byKey(NotificationsSection.badgesOffKey), findsOneWidget);
    expect(
      find.text('Turn on Badges for slim-m in iOS Settings.'),
      findsOneWidget,
    );
  });

  testWidgets('stays quiet while Badges is on', (tester) async {
    await _open(tester, allowed: true);
    expect(find.byKey(NotificationsSection.badgesOffKey), findsNothing);
  });
}
