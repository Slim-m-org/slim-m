// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The consent step before a module is installed or updated
/// (docs/decisions/0067-module-install-consent.md): an unverified module with
/// capabilities needs an explicit acknowledgement, a verified one does not,
/// and an update only asks again when it wants access the install lacked.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_install_consent.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_row.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

import 'dock_consent_harness.dart';

Finder _pageButton(String label) => find.text(label);

bool _sheetButtonDisabled(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label)).disabled;

/// Text in the consent sheet only; the page behind repeats some sentences.
Finder _inSheet(String text) =>
    find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

Finder get _verifiedBadge => find.byType(DockVerifiedBadge);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('unverified with access: Install waits for the acknowledgement', (
    tester,
  ) async {
    final installs = await consentPump(
      tester,
      community: true,
      asks: ['kv.store', 'message.post'],
    );
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not verified'), findsOneWidget);
    expect(_sheetButtonDisabled(tester, 'Install'), isTrue);
    expect(installs, isEmpty);

    await writeSnapshot(tester, 'dock-consent-unverified-phone');
    await tester.tap(find.text('I understand what this module can do'));
    await tester.pumpAndSettle();
    expect(_sheetButtonDisabled(tester, 'Install'), isFalse);
    await tester.tap(find.widgetWithText(AppButton, 'Install'));
    await tester.pumpAndSettle();
    expect(installs, hasLength(1));
  });

  testWidgets('the sheet lists each requested capability sentence', (
    tester,
  ) async {
    await consentPump(
      tester,
      community: true,
      asks: ['kv.store', 'message.post'],
    );
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    expect(
      find.text('Can keep its own private data on your server.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Can post messages in your space as whoever runs it, marked as '
        'this module.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Each run is limited to 32 MB'), findsOneWidget);
  });

  testWidgets('verified with access: Install is enabled straight away', (
    tester,
  ) async {
    final installs = await consentPump(tester, asks: ['message.post']);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();

    expect(find.text('I understand what this module can do'), findsNothing);
    expect(find.textContaining('Not verified'), findsNothing);
    expect(_sheetButtonDisabled(tester, 'Install'), isFalse);
    await writeSnapshot(tester, 'dock-consent-verified-phone');
    await tester.tap(find.widgetWithText(AppButton, 'Install'));
    await tester.pumpAndSettle();
    expect(installs, hasLength(1));
  });

  testWidgets('the page keeps Install clear of the access card above it', (
    tester,
  ) async {
    await consentPump(tester, asks: ['message.post']);
    final last = tester.getRect(
      find.textContaining('Posts as whoever runs it'),
    );
    final install = tester.getRect(find.text('Install v1.0.0'));
    expect(install.top - last.bottom, greaterThan(32));
  });

  testWidgets('the registry sentence hides behind the badge until tapped', (
    tester,
  ) async {
    await consentPump(tester, asks: ['message.post']);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    const sentence = 'From the official slim-addons registry.';
    expect(find.text(sentence), findsNothing);
    final badge = find.byTooltip(sentence);
    expect(badge, findsOneWidget);
    expect(find.bySemanticsLabel(sentence), findsOneWidget);
    await tester.tap(badge);
    await tester.pump();
    expect(find.text(sentence), findsOneWidget);
  });

  testWidgets('the badge has a 44dp touch target on a phone', (tester) async {
    await consentPump(tester, asks: ['message.post']);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    final badge = find.byTooltip('From the official slim-addons registry.');
    expect(tester.getSize(badge), const Size.square(AppSizes.icon16));
    await tester.tapAt(tester.getCenter(badge) + const Offset(18, 0));
    await tester.pump();
    expect(
      find.text('From the official slim-addons registry.'),
      findsOneWidget,
    );
  });

  testWidgets('the badge keeps its drawn size as the target on desktop', (
    tester,
  ) async {
    await consentPump(
      tester,
      asks: ['message.post'],
      size: const Size(1400, 1000),
    );
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    final badge = find.byTooltip('From the official slim-addons registry.');
    await tester.tapAt(tester.getCenter(badge) + const Offset(18, 0));
    await tester.pump();
    expect(find.text('From the official slim-addons registry.'), findsNothing);
  });

  testWidgets('cancelling installs nothing', (tester) async {
    final installs = await consentPump(
      tester,
      community: true,
      asks: ['kv.store'],
    );
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(installs, isEmpty);
    expect(find.text('Install v1.0.0'), findsOneWidget);
  });

  testWidgets('unverified without access gets a line but no checkbox', (
    tester,
  ) async {
    await consentPump(tester, community: true);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not verified'), findsOneWidget);
    expect(
      find.text('It runs code on your server with no access to your space.'),
      findsOneWidget,
    );
    expect(find.text('I understand what this module can do'), findsNothing);
    expect(_sheetButtonDisabled(tester, 'Install'), isFalse);
  });

  testWidgets('verified without access installs with no consent step', (
    tester,
  ) async {
    final installs = await consentPump(tester);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    expect(installs, hasLength(1));
  });

  testWidgets('an update asking for new access shows the consent step', (
    tester,
  ) async {
    final installs = await consentPump(
      tester,
      community: true,
      version: '2.0.0',
      installedVersion: '1.0.0',
      installedHad: ['kv.store'],
      asks: ['kv.store', 'message.post'],
    );
    await tester.tap(_pageButton('Update to v2.0.0'));
    await tester.pumpAndSettle();

    expect(find.text('This version asks for new access. It can:'), findsOne);
    expect(find.textContaining('post messages'), findsOneWidget);
    expect(
      find.textContaining('keep its own private data'),
      findsNothing,
      reason: 'only what is new is asked about',
    );
    expect(_sheetButtonDisabled(tester, 'Update'), isTrue);
    expect(installs, isEmpty);
  });

  testWidgets('an update asking for nothing new goes straight through', (
    tester,
  ) async {
    final installs = await consentPump(
      tester,
      community: true,
      version: '2.0.0',
      installedVersion: '1.0.0',
      installedHad: ['kv.store'],
      asks: ['kv.store'],
    );
    await tester.tap(_pageButton('Update to v2.0.0'));
    await tester.pumpAndSettle();
    expect(installs, hasLength(1));
  });

  testWidgets('the Verified badge shows on official modules only', (
    tester,
  ) async {
    await consentPump(tester);
    expect(_verifiedBadge, findsOneWidget);
  });

  testWidgets('a community module has no Verified badge', (tester) async {
    await consentPump(tester, community: true);
    expect(_verifiedBadge, findsNothing);
  });

  testWidgets('the Dock list marks official rows and not community ones', (
    tester,
  ) async {
    const entry = api.DockIndexEntry(
      id: 'ladder',
      name: 'ladder',
      version: '1.0.0',
      summary: 's',
    );
    for (final source in [null, 'comm']) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: DockModuleRow(entry: entry, installed: null, source: source),
          ),
        ),
      );
      expect(_verifiedBadge, source == null ? findsOneWidget : findsNothing);
    }
  });

  testWidgets('tapping the badge in a row still opens the module', (
    tester,
  ) async {
    const entry = api.DockIndexEntry(
      id: 'ladder',
      name: 'ladder',
      version: '1.0.0',
      summary: 's',
    );
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const Scaffold(
                body: DockModuleRow(entry: entry, installed: null),
              ),
            ),
            GoRoute(
              path: '/:rest(.*)',
              builder: (context, state) => const Text('opened module'),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byTooltip('Verified'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('opened module'), findsOneWidget);
  });

  testWidgets('the row marks Verified with an icon, not a chip', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await consentPump(tester);
    expect(find.text('VERIFIED'), findsNothing);
    expect(find.byTooltip('Verified'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Verified')), findsWidgets);
    semantics.dispose();
  });

  for (final (label, size) in [
    ('phone', const Size(420, 1000)),
    ('desktop', const Size(1100, 900)),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('the registry badge tip at $label ${brightness.name}', (
        tester,
      ) async {
        await consentPump(
          tester,
          asks: ['message.post'],
          size: size,
          brightness: brightness,
        );
        await tester.tap(_pageButton('Install v1.0.0'));
        await tester.pumpAndSettle();
        // The sheet is the topmost route, so its badge is the last one built.
        final badge = find.byIcon(AppIcons.verified).last;
        await tester.tap(badge);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.text('From the official slim-addons registry.'),
          findsWidgets,
        );
        await writeSnapshot(
          tester,
          'dock-consent-badge-tip-$label-${brightness.name}',
        );
      });
    }
  }

  testWidgets('the consent sheet at desktop width', (tester) async {
    await consentPump(
      tester,
      community: true,
      asks: ['kv.store', 'message.post'],
      size: const Size(1100, 900),
    );
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    await writeSnapshot(tester, 'dock-consent-unverified-desktop');
  });

  group('platform capabilities', () {
    const extras = {
      'subscriptions': [
        {'event': 'message.created'},
        {'event': 'member.joined'},
        {'event': 'member.left'},
        {'event': 'voice.session.closed'},
      ],
      'data': {'max_mb': 16},
    };

    testWidgets('each new capability gets its plain line', (tester) async {
      await consentPump(
        tester,
        community: true,
        asks: ['events', 'data.store', 'log.read'],
        extras: extras,
      );
      await tester.tap(_pageButton('Install v1.0.0'));
      await tester.pumpAndSettle();
      expect(
        _inSheet(
          'Can be told when messages are posted, members join or leave, '
          'and voice calls end.',
        ),
        findsOneWidget,
      );
      expect(
        _inSheet('Can keep its own data on your server, up to 16 MB.'),
        findsOneWidget,
      );
      expect(
        _inSheet('Can see when members join and leave voice calls.'),
        findsOneWidget,
      );
      expect(_sheetButtonDisabled(tester, 'Install'), isTrue);
    });

    testWidgets('an update that adds one asks again and blocks Update', (
      tester,
    ) async {
      final installs = await consentPump(
        tester,
        community: true,
        version: '2.0.0',
        installedVersion: '1.0.0',
        installedHad: ['kv.store'],
        asks: ['kv.store', 'log.read'],
        extras: extras,
      );
      await tester.tap(_pageButton('Update to v2.0.0'));
      await tester.pumpAndSettle();
      expect(
        _inSheet('Can see when members join and leave voice calls.'),
        findsOneWidget,
      );
      expect(_sheetButtonDisabled(tester, 'Update'), isTrue);
      expect(installs, isEmpty);
    });

    testWidgets('an update that adds none goes straight through', (
      tester,
    ) async {
      final installs = await consentPump(
        tester,
        community: true,
        version: '2.0.0',
        installedVersion: '1.0.0',
        installedHad: ['events'],
        asks: ['events'],
        extras: extras,
      );
      await tester.tap(_pageButton('Update to v2.0.0'));
      await tester.pumpAndSettle();
      expect(installs, hasLength(1));
    });
  });
}
