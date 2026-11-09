// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Start on login setting shows what the system reports and changes it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/providers/autostart_setting.dart';
import 'package:slimm_app/src/features/settings/widgets/start_on_login_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/async_wait.dart';

class _FakeAutostart implements Autostart {
  _FakeAutostart({this.registered = false, this.fails = false});

  bool registered;
  final bool fails;
  int repairs = 0;

  /// When set, a change waits for it before it is applied.
  Future<void>? hold;

  @override
  Future<void> repair() async => repairs++;

  @override
  Future<bool> isEnabled() async => registered;

  @override
  Future<void> setEnabled(bool on) async {
    await hold;
    if (fails) throw StateError('no');
    registered = on;
  }
}

Future<void> _pump(WidgetTester tester, Autostart? autostart) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [autostartProvider.overrideWith((ref) async => autostart)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: StartOnLoginRow()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool _switchValue(WidgetTester tester) =>
    tester.widget<AppToggle>(find.byType(AppToggle)).value;

class _Records implements LogSink {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  testWidgets('it shows the system state and turning it on registers', (
    tester,
  ) async {
    final autostart = _FakeAutostart(registered: false);
    await _pump(tester, autostart);
    expect(find.text('Start on login'), findsOneWidget);
    expect(_switchValue(tester), isFalse);

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();
    expect(autostart.registered, isTrue);
    expect(_switchValue(tester), isTrue, reason: 'read back from the system');
  });

  testWidgets('an existing registration shows as on', (tester) async {
    await _pump(tester, _FakeAutostart(registered: true));
    expect(_switchValue(tester), isTrue);
  });

  testWidgets('a failure says so and the switch stays where the system is', (
    tester,
  ) async {
    await _pump(tester, _FakeAutostart(fails: true));
    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();
    expect(find.text('Could not change this, try again.'), findsOneWidget);
    expect(_switchValue(tester), isFalse);
  });

  testWidgets('leaving before the system answers still reads the state back', (
    tester,
  ) async {
    final answer = Completer<void>();
    final autostart = _FakeAutostart(registered: false)..hold = answer.future;
    final container = ProviderContainer(
      overrides: [autostartProvider.overrideWith((ref) async => autostart)],
    );
    addTearDown(container.dispose);
    container.listen(autostartEnabledProvider, (_, _) {});
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: StartOnLoginRow()),
        ),
      ),
    );
    await pumpFrames(tester);

    await tester.tap(find.bySubtype<AppToggle>());
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    answer.complete();
    await pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(container.read(autostartEnabledProvider).value, isTrue);
  });

  testWidgets('a host with no login launch shows nothing', (tester) async {
    await _pump(tester, null);
    expect(find.text('Start on login'), findsNothing);
  });

  test('start repairs the registration through the provider', () async {
    final fake = _FakeAutostart(registered: true);
    final container = ProviderContainer(
      overrides: [autostartProvider.overrideWith((ref) async => fake)],
    );
    addTearDown(container.dispose);
    await repairAutostart(container);
    expect(fake.repairs, 1);
  });

  test(
    'a host with no login launch repairs nothing and logs no swallowed error',
    () async {
      final container = ProviderContainer(
        overrides: [autostartProvider.overrideWith((ref) async => null)],
      );
      addTearDown(container.dispose);
      final sink = _Records();
      AppLog.install(sink);
      addTearDown(() => AppLog.install(null));

      await repairAutostart(container);

      expect(sink.records.where((r) => r.message.contains('repair')), isEmpty);
    },
  );
}
