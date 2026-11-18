// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A page pushed inside a settings pane keeps the nav and close beside it,
/// names its way back, carries itself in the link, and asks before a page
/// with unsaved work is left.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/routing/settings_pages.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_harness.dart';

const _wide = Size(1280, 900);
const _phone = Size(390, 844);

/// Below the settings two-pane width, where the roles pane still shows two columns.
const _narrowDesktop = Size(700, 844);

class _Guard implements SettingsLeaveGuard {
  bool answer = false;
  int asked = 0;

  @override
  bool get blocking => true;

  @override
  Future<bool> confirmLeave() async {
    asked++;
    return answer;
  }
}

class _GuardedPage extends StatefulWidget {
  const _GuardedPage(this.guard);

  final _Guard guard;

  @override
  State<_GuardedPage> createState() => _GuardedPageState();
}

class _GuardedPageState extends State<_GuardedPage> {
  @override
  void initState() {
    super.initState();
    SettingsSubPages.of(context).setGuard(widget.guard);
  }

  @override
  Widget build(BuildContext context) => const Text('guarded body');
}

/// A pane with a draft of its own, no page pushed: the role editor's shape.
class _DraftedPane extends StatefulWidget {
  const _DraftedPane(this.guard);

  final _Guard guard;

  @override
  State<_DraftedPane> createState() => _DraftedPaneState();
}

class _DraftedPaneState extends State<_DraftedPane> {
  late final _stack = SettingsSubPages.of(context);

  @override
  void initState() {
    super.initState();
    _stack.setPaneGuard(widget.guard);
  }

  @override
  void dispose() {
    _stack.releasePaneGuard(widget.guard);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('drafted pane');
}

SettingsSubPage _page(
  String id, {
  String? urlId,
  bool ownsHeader = false,
  WidgetBuilder? builder,
}) => SettingsSubPage(
  id: id,
  title: 'Page $id',
  backLabel: 'Back to Appearance',
  urlId: urlId,
  ownsHeader: ownsHeader,
  builder: builder ?? (_) => Text('body $id'),
);

class _Rig {
  final told = <String>[];
  final panesTold = <String?>[];
  SettingsSubPage pushed = _page('one', urlId: 'one');
  final guard = _Guard();

  Widget scaffold({String? page, String pane = 'appearance'}) =>
      SettingsPanesScaffold(
        title: 'Settings',
        backTooltip: 'Back to channels',
        backFallback: '/',
        initialPaneId: pane,
        initialPageId: page,
        onPageChanged: (pane, page) => told.add('$pane:$page'),
        onPaneChanged: panesTold.add,
        groups: [
          SettingsPaneGroup(
            label: 'You',
            panes: [
              SettingsPane(
                id: 'appearance',
                label: 'Appearance',
                builder: (context) => TextButton(
                  onPressed: () => SettingsSubPages.of(context).push(pushed),
                  child: const Text('open page'),
                ),
                subPages: {
                  'two': () => [
                    _page('one', urlId: 'one'),
                    _page('two', urlId: 'two'),
                  ],
                  'guarded': () => [
                    _page('g', builder: (_) => _GuardedPage(guard)),
                  ],
                },
              ),
              SettingsPane(
                id: 'other',
                label: 'Other',
                builder: (_) => const Text('other pane'),
              ),
              SettingsPane(
                id: 'drafted',
                label: 'Drafted',
                builder: (_) => _DraftedPane(guard),
              ),
            ],
          ),
        ],
      );

  Future<void> pump(
    WidgetTester tester,
    Size size, {
    String? page,
    String pane = 'appearance',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await relink(tester, pane: pane, page: page);
  }

  /// Rebuilds with a new location, as browser Back or Forward does.
  Future<void> relink(
    WidgetTester tester, {
    required String pane,
    String? page,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: scaffold(page: page, pane: pane),
      ),
    );
    await _settle(tester);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await _settle(tester);
}

void main() {
  testWidgets('beside the nav the rail keeps its back arrow and title put '
      'while a page is open', (tester) async {
    final rig = _Rig();
    await rig.pump(tester, _wide);
    final navBack = find.byTooltip('Back to channels');
    final title = tester.getTopLeft(find.text('Settings'));
    expect(navBack.hitTestable(), findsOneWidget);

    await _tap(tester, find.text('open page'));
    expect(navBack.hitTestable(), findsOneWidget);
    expect(find.byTooltip('Back to Appearance').hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.text('Settings')), title);

    await _tap(tester, find.byTooltip('Back to Appearance'));
    expect(navBack.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.text('Settings')), title);
  });

  testWidgets('beside the nav a page takes the heading row and keeps close', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester, _wide);
    final close = tester.getRect(find.byTooltip('Close settings'));

    await _tap(tester, find.text('open page'));

    expect(find.text('body one'), findsOneWidget);
    expect(find.text('Page one'), findsOneWidget);
    expect(find.text('open page'), findsNothing);
    expect(find.text('Other'), findsOneWidget);
    expect(tester.getRect(find.byTooltip('Close settings')), close);
    final back = tester.getRect(find.byTooltip('Back to Appearance'));
    expect(back.center.dy, closeTo(close.center.dy, 0.5));
    expect(rig.told, ['appearance:one']);

    await _tap(tester, find.byTooltip('Back to Appearance'));

    expect(find.text('open page'), findsOneWidget);
    expect(find.text('body one'), findsNothing);
    expect(rig.told, ['appearance:one', 'appearance:null']);
  });

  testWidgets('on a phone the app bar names the page and its way back', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester, _phone);

    await _tap(tester, find.text('open page'));
    expect(find.text('Page one'), findsOneWidget);
    expect(find.byTooltip('Back to Appearance'), findsOneWidget);

    await _tap(tester, find.byTooltip('Back to Appearance'));
    expect(find.text('open page'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
  });

  testWidgets('a link opens its pages and back walks down them', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester, _wide, page: 'two');

    expect(find.text('body two'), findsOneWidget);
    expect(rig.told, isEmpty, reason: 'the link already says page two');
    await _tap(tester, find.byTooltip('Back to Appearance'));
    expect(find.text('body one'), findsOneWidget);
    await _tap(tester, find.byTooltip('Back to Appearance'));
    expect(find.text('open page'), findsOneWidget);
    expect(rig.told, ['appearance:one', 'appearance:null']);
  });

  testWidgets('a page that owns its header gets no insets', (tester) async {
    final rig = _Rig()
      ..pushed = _page(
        'own',
        ownsHeader: true,
        builder: (_) => const SizedBox.expand(key: Key('own-page')),
      );
    await rig.pump(tester, _wide);

    await _tap(tester, find.text('open page'));

    final page = tester.getRect(find.byKey(const Key('own-page')));
    expect(page.topLeft, const Offset(240, 0));
    expect(page.bottomRight, Offset(_wide.width, _wide.height));
    expect(find.byTooltip('Back to Appearance'), findsNothing);
  });

  testWidgets('a guarded page asks before another pane opens', (tester) async {
    final rig = _Rig();
    await rig.pump(tester, _wide, page: 'guarded');
    expect(find.text('guarded body'), findsOneWidget);

    await _tap(tester, find.text('Other'));
    expect(rig.guard.asked, 1);
    expect(find.text('guarded body'), findsOneWidget);

    rig.guard.answer = true;
    await _tap(tester, find.text('Other'));
    expect(rig.guard.asked, 2);
    expect(find.text('other pane'), findsOneWidget);

    await _tap(tester, find.text('Appearance'));
    expect(find.text('open page'), findsOneWidget, reason: 'the stack cleared');
  });

  testWidgets('a guarded page asks before back and close', (tester) async {
    final rig = _Rig();
    await rig.pump(tester, _wide, page: 'guarded');

    await _tap(tester, find.byTooltip('Back to Appearance'));
    await _tap(tester, find.byTooltip('Close settings'));

    expect(rig.guard.asked, 2);
    expect(find.text('guarded body'), findsOneWidget);
  });

  testWidgets('a pane draft asks before close and before another pane', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester, _wide, pane: 'drafted');

    await _tap(tester, find.byTooltip('Close settings'));
    await _tap(tester, find.text('Other'));
    expect(rig.guard.asked, 2);
    expect(find.text('drafted pane'), findsOneWidget);

    rig.guard.answer = true;
    await _tap(tester, find.text('Other'));
    expect(find.text('other pane'), findsOneWidget);
  });

  testWidgets('a pane draft asks before the location moves to another pane', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester, _wide, pane: 'drafted');

    await rig.relink(tester, pane: 'other');
    expect(rig.guard.asked, 1);
    expect(find.text('drafted pane'), findsOneWidget);
    expect(rig.panesTold, ['drafted'], reason: 'the location goes back');

    await rig.relink(tester, pane: 'drafted');
    rig.guard.answer = true;
    await rig.relink(tester, pane: 'other');
    expect(rig.guard.asked, 2);
    expect(find.text('other pane'), findsOneWidget);
  });

  testWidgets('below the two-pane width, back from a pane draft asks first', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester, _narrowDesktop, pane: 'drafted');

    await _tap(tester, find.byTooltip('Back to settings'));
    expect(rig.guard.asked, 1);
    expect(find.text('drafted pane'), findsOneWidget);

    rig.guard.answer = true;
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(rig.guard.asked, 2);
    expect(find.text('drafted pane'), findsNothing);
    expect(find.text('Drafted'), findsOneWidget, reason: 'back on the nav');
    expect(tester.takeException(), isNull);
  });

  testWidgets('below the two-pane width, system back from a pane with no '
      'draft lands on the nav like the back arrow', (tester) async {
    final rig = _Rig();
    await rig.pump(tester, _narrowDesktop, pane: 'other');
    expect(find.text('other pane'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await _settle(tester);

    expect(rig.guard.asked, 0);
    expect(find.text('other pane'), findsNothing);
    expect(find.text('Drafted'), findsOneWidget, reason: 'back on the nav');
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone system back leaves the page, not settings', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester, _phone);
    await _tap(tester, find.text('open page'));

    await tester.binding.handlePopRoute();
    await _settle(tester);

    expect(find.text('open page'), findsOneWidget);
    expect(find.text('body one'), findsNothing);
  });

  testWidgets('system back on a guarded page asks first', (tester) async {
    final rig = _Rig();
    await rig.pump(tester, _phone, page: 'guarded');

    await tester.binding.handlePopRoute();
    await _settle(tester);

    expect(rig.guard.asked, 1);
    expect(find.text('guarded body'), findsOneWidget);
  });

  group('Appearance on the real settings route', () {
    Future<GoRouter> open(WidgetTester tester, Size size, String start) async {
      GoRouter.optionURLReflectsImperativeAPIs = true;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = settingsContainer(0);
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => TextButton(
              onPressed: () => context.push(start),
              child: const Text('open'),
            ),
          ),
          GoRoute(
            path: Routes.personalSettings,
            pageBuilder: personalSettingsPage,
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            routerConfig: router,
          ),
        ),
      );
      await _settle(tester);
      await _tap(tester, find.text('open'));
      return router;
    }

    String location(GoRouter router) =>
        router.routeInformationProvider.value.uri.toString();

    testWidgets('Browse themes opens Themes in the pane and the link says so', (
      tester,
    ) async {
      final router = await open(
        tester,
        _wide,
        Routes.personalSettingsPane('appearance'),
      );

      await _tap(tester, find.text('Browse themes'));
      expect(find.byKey(const Key('themes-page-list')), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget, reason: 'the nav stays');
      expect(
        location(router),
        Routes.personalSettingsPage('appearance', 'themes'),
      );

      await _tap(tester, find.byTooltip('Back to Appearance'));
      expect(find.text('Browse themes'), findsOneWidget);
      expect(location(router), Routes.personalSettingsPane('appearance'));
    });

    testWidgets('a new-theme link opens the editor above Themes', (
      tester,
    ) async {
      final router = await open(
        tester,
        _phone,
        Routes.personalSettingsPage('appearance', 'new-theme'),
      );
      expect(find.text('New theme'), findsOneWidget);

      await _tap(tester, find.byTooltip('Back to Themes'));
      expect(find.byKey(const Key('themes-page-list')), findsOneWidget);
      expect(
        location(router),
        Routes.personalSettingsPage('appearance', 'themes'),
      );

      await _tap(tester, find.byTooltip('Back to Appearance'));
      expect(find.text('Browse themes'), findsOneWidget);
    });
  });
}
