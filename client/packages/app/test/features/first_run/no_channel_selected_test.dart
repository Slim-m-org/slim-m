// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The home shown with no channel chosen: a welcome until setup is done or
/// skipped, the update as a card rather than a dialog, and otherwise a quiet
/// look at what is waiting.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/features/first_run/providers/first_run_controller.dart';
import 'package:slimm_app/src/features/first_run/providers/first_run_rules.dart';
import 'package:slimm_app/src/features/messages/providers/inbox.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/whats_new/providers/whats_new_controller.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/widgets/whats_new_gate.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

class _Server extends ChosenServer {
  @override
  Uri? build() => Uri.parse('https://space.test');
}

const _space = 'https://space.test';

Channel _channel(String name) => Channel(
  id: name,
  name: name,
  kind: 'text',
  createdAt: 0,
  cursor: 5,
  lastReadSeq: 2,
  mentionedSeq: 0,
  isPersonalSpace: false,
  position: 0,
  slowModeSeconds: 0,
  joinMuted: false,
);

final _me = api.Me(
  id: 'u1',
  username: 'new',
  displayName: 'New',
  createdAt: DateTime.now().millisecondsSinceEpoch,
  permissions: 0,
);

late SlimmDatabase _db;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool touch = false,
  List<InboxEntry> inbox = const [],
  Size size = const Size(1000, 800),
  bool withGate = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      meProvider.overrideWith((ref) => _me),
      storeProvider.overrideWith((ref) => MessageStore(_db)),
      chosenServerProvider.overrideWith(_Server.new),
      isFreshInstallProvider.overrideWith((ref) => false),
      serverInfoProvider.overrideWith(
        (ref) async => const api.Version(
          name: 'slim-m',
          version: '1',
          protocol: 1,
          spaceName: 'Test Space',
        ),
      ),
      inboxProvider.overrideWith((ref) => Stream.value(inbox)),
    ],
  );
  addTearDown(container.dispose);
  const home = Scaffold(body: NoChannelSelected());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: AppTouchTargets(
          enabled: touch,
          child: withGate ? const WhatsNewGate(child: home) : home,
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    await container.read(meProvider.future);
    await container.read(preferencesProvider.future);
    await pumpEventQueue();
  });
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      lastSeenWhatsNewVersionKey: '0.111.0',
    });
    PackageInfo.setMockInitialValues(
      appName: 'slim-m',
      packageName: 'top.npcserver.slimm',
      version: '0.111.0',
      buildNumber: '1',
      buildSignature: '',
    );
    _db = SlimmDatabase(NativeDatabase.memory());
  });
  tearDown(() => _db.close());

  group('first visit', () {
    testWidgets('welcomes by Space name and offers setup', (tester) async {
      await _pump(tester);
      expect(find.text('Welcome to Test Space'), findsOneWidget);
      expect(find.text('Get started'), findsOneWidget);
      expect(find.text('Run setup'), findsNothing);
    });

    testWidgets('the primary button sits on the column axis', (tester) async {
      await _pump(tester, size: const Size(480, 800));
      final axis = tester.getCenter(find.text('Welcome to Test Space')).dx;
      expect(axis, moreOrLessEquals(240, epsilon: 0.5));
      expect(
        tester.getCenter(find.text('Get started')).dx,
        moreOrLessEquals(axis, epsilon: 0.5),
      );
    });

    testWidgets('starting opens setup and remembers the outcome', (
      tester,
    ) async {
      final container = await _pump(tester);
      await tester.tap(find.text('Get started'));
      await tester.pump();
      final state = container.read(firstRunControllerProvider);
      expect((state.active, state.replay), (true, false));

      await tester.runAsync(
        () => container.read(firstRunControllerProvider.notifier).complete(),
      );
      await tester.pump();
      expect(find.text('Get started'), findsNothing);
      expect(find.text('Test Space'), findsOneWidget);
    });

    testWidgets('is gone once setup was finished or skipped before', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        firstRunDoneKey(_space, 'u1'): true,
        lastSeenWhatsNewVersionKey: '0.111.0',
      });
      await _pump(tester);
      expect(find.text('Get started'), findsNothing);
      expect(find.textContaining('Welcome'), findsNothing);
    });
  });

  group('after an update', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        firstRunDoneKey(_space, 'u1'): true,
        lastSeenWhatsNewVersionKey: '0.110.0',
      });
    });

    testWidgets('shows a card, not the dialog, then never again', (
      tester,
    ) async {
      await _pump(tester, withGate: true);
      expect(find.text("What's new in 0.111.0"), findsOneWidget);
      expect(find.text("What's new"), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(lastSeenWhatsNewVersionKey), '0.111.0');

      await tester.pumpWidget(const SizedBox());
      await _pump(tester, withGate: true);
      expect(find.textContaining("What's new"), findsNothing);
    });

    testWidgets('Got it puts the card away', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Got it'));
      await tester.pump();
      expect(find.text("What's new in 0.111.0"), findsNothing);
    });
  });

  group('every day', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        firstRunDoneKey(_space, 'u1'): true,
        lastSeenWhatsNewVersionKey: '0.111.0',
      });
    });

    testWidgets('names the Space, lists what is waiting, keeps shortcuts', (
      tester,
    ) async {
      await _pump(
        tester,
        inbox: [
          InboxEntry(channel: _channel('general'), mentioned: false, unread: 3),
        ],
      );
      expect(find.byIcon(AppIcons.hash), findsWidgets);
      expect(find.text('Test Space'), findsOneWidget);
      expect(find.text('Pick a channel to start reading.'), findsOneWidget);
      expect(find.text('WAITING FOR YOU'), findsOneWidget);
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('Quick switcher'), findsOneWidget);
      expect(find.text('Get started'), findsNothing);
      expect(find.textContaining("What's new"), findsNothing);
    });

    testWidgets('is quiet with nothing waiting', (tester) async {
      await _pump(tester);
      expect(find.text('WAITING FOR YOU'), findsNothing);
    });

    testWidgets('drops the keycaps on a touch layout', (tester) async {
      await _pump(tester, touch: true);
      expect(find.byType(AppKbd), findsNothing);
    });

    testWidgets('the shortcut list is centred under the heading', (
      tester,
    ) async {
      await _pump(tester, size: const Size(480, 800));
      final centre = tester.getCenter(find.text('Test Space')).dx;
      expect(centre, moreOrLessEquals(240, epsilon: 0.5));
      for (final label in ['Quick switcher', 'Next channel', 'Open settings']) {
        final row = find.ancestor(
          of: find.text(label),
          matching: find.byType(Row),
        );
        final kbd = find.descendant(
          of: row.first,
          matching: find.byType(AppKbd),
        );
        final labelRight = tester.getTopRight(find.text(label)).dx;
        final keysLeft = tester.getTopLeft(kbd.first).dx;
        expect(
          (labelRight + keysLeft) / 2,
          moreOrLessEquals(centre, epsilon: 1),
          reason: label,
        );
      }
    });
  });
}
