// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reset notifications shows only on an iPhone and asks native for a fresh
/// push token when pressed.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/settings/widgets/notification_troubleshooting_card.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/push/providers/push_channel_providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

class _FakeApnsChannel extends ApnsTokenChannel {
  _FakeApnsChannel() : super(isIOS: false);

  int resets = 0;

  @override
  Future<bool> resetRegistration() async {
    resets++;
    return false;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _FakeApnsChannel channel,
) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      apnsTokenChannelProvider.overrideWithValue(channel),
    ],
  )..read(preferencesProvider);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: NotificationTroubleshootingCard()),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an iPhone gets the row and pressing it asks for a new token', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final channel = _FakeApnsChannel();
    final container = await _pump(tester, channel);

    await tester.ensureVisible(find.text('Reset'));
    await tester.tap(find.text('Reset'));
    await tester.pump();

    expect(channel.resets, 1);
    expect(
      container.read(toastsProvider).map((t) => t.message),
      contains('Nothing to reset here.'),
    );
    final toasts = container.read(toastsProvider.notifier);
    for (final toast in container.read(toastsProvider)) {
      toasts.dismiss(toast.id);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('other platforms never show it', (tester) async {
    await _pump(tester, _FakeApnsChannel());
    expect(find.text('Reset notifications'), findsNothing);
  });
}
