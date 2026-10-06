// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A banner appearing above the shell must not tear down the shell below it:
/// every banner host keeps one parent chain for its child, so the child's
/// state (a half-typed field, a scroll offset) survives show and hide.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/database_key_store.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/widgets/new_device_banner_host.dart';
import 'package:slimm_app/src/widgets/update_banner_host.dart';
import 'package:slimm_data/data.dart' show DatabaseResetReason;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

class _Stateful extends StatefulWidget {
  const _Stateful();

  @override
  State<_Stateful> createState() => _StatefulState();
}

class _StatefulState extends State<_Stateful> {
  static var inits = 0;
  final controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    inits++;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: TextField(controller: controller));
}

Future<void> _pump(
  WidgetTester tester,
  Widget host,
  List<Override> overrides,
) async {
  SharedPreferences.setMockInitialValues({});
  _StatefulState.inits = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: host,
      ),
    ),
  );
  await tester.pump();
  await tester.enterText(find.byType(TextField), 'half typed');
  expect(_StatefulState.inits, 1);
}

void _expectKept(WidgetTester tester) {
  expect(_StatefulState.inits, 1, reason: 'the child must not be re-created');
  expect(find.text('half typed'), findsOneWidget);
}

void main() {
  testWidgets('the new-device banner appearing keeps the child state', (
    tester,
  ) async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    await _pump(tester, const NewDeviceBannerHost(child: _Stateful()), [
      liveEventsProvider.overrideWithValue(events.stream),
    ]);

    events.add(
      const NewDeviceSignIn(
        deviceId: 'd2',
        deviceName: 'Ada laptop',
        clientKind: 'desktop',
        signedInAt: 1700000000000,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('New sign-in'), findsOneWidget);
    _expectKept(tester);
  });

  testWidgets('the update banner appearing keeps the child state', (
    tester,
  ) async {
    await _pump(
      tester,
      const UpdateBannerHost(ownsBanner: false, child: _Stateful()),
      [
        updateWatcherProvider.overrideWith(
          (ref) => UpdateWatcher(ref, shouldRun: () => false),
        ),
      ],
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(UpdateBannerHost)),
    );
    container.read(inSessionUpdateProvider.notifier).state = const ClientUpdate(
      version: '9.9.9',
      releaseUrl: 'https://example.invalid/release',
      format: InstallFormat.unknown,
    );
    await tester.pump();

    expect(find.textContaining('9.9.9'), findsOneWidget);
    _expectKept(tester);
  });

  testWidgets('the database reset notice appearing keeps the child state', (
    tester,
  ) async {
    await _pump(
      tester,
      const DatabaseResetNotice(child: _Stateful()),
      const [],
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DatabaseResetNotice)),
    );
    container.read(databaseResetProvider.notifier).state =
        DatabaseResetReason.keyMissing;
    await tester.pump();

    expect(find.text('Dismiss'), findsOneWidget);
    _expectKept(tester);
  });
}
