// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's blank-space "Create channel/Create category" menu
/// (`channel_rail.dart`) wraps the whole scrollable list, not one row, so it
/// must not also claim its own tab stop on top of it: that painted a focus
/// ring around the entire rail instead of a row - the owner: "sidebar
/// highlighted blue somehow? not ideal". `ownsFocusNode: false` is the fix;
/// this proves the geometry at both a phone and a desktop width, and that
/// the keyboard route into the menu still works from a real stop already
/// inside the rail, so nothing was made unreachable to fix the look.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

/// A phone width (below `kCompactWidth`) and a desktop width, since the rail
/// itself does not change shape between them but the ticket asks the fix be
/// proven at both.
const _widths = [390.0, 1400.0];

/// Only [ChannelRail] mounted, not the whole shell: a handful of real tab
/// stops (rows, add-channel glyphs, the footer) rather than a whole screen's
/// worth, so a bounded number of Tab presses can reach every one of them.
Future<({ProviderContainer container, SlimmDatabase db})> _pumpRailOnly(
  WidgetTester tester,
  double width,
) async {
  tester.view.physicalSize = Size(width, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer();
  final router = GoRouter(
    initialLocation: Routes.channel('c-general'),
    routes: [
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) => const Scaffold(body: ChannelRail()),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

/// Whether [element] is itself one of the rail's always-visible "+"
/// add-channel glyphs: small, and painting the add icon somewhere below it.
/// The size bound matters as much as the icon check, since the root focus
/// scope's own subtree contains every icon in the rail and would otherwise
/// match before a single Tab is sent.
bool _isAddChannelGlyph(Element element) {
  final renderObject = element.renderObject;
  if (renderObject is! RenderBox || !renderObject.hasSize) return false;
  if (renderObject.size.width > 80 || renderObject.size.height > 80) {
    return false;
  }
  var found = false;
  void visit(Element e) {
    if (found) return;
    final widget = e.widget;
    if (widget is Icon && widget.icon == AppIcons.add) {
      found = true;
      return;
    }
    e.visitChildren(visit);
  }

  visit(element);
  return found;
}

/// Sends Tab until the primary focus's own subtree satisfies [match], or
/// fails loudly rather than silently asserting against whatever the last tab
/// happened to land on.
Future<void> _tabUntil(
  WidgetTester tester,
  bool Function(Element) match, {
  int max = 60,
}) async {
  for (var i = 0; i < max; i++) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context != null && match(context as Element)) return;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  fail('did not reach the target focus stop within $max tab presses');
}

/// Every `DecoratedBox` currently painting the generic focus ring
/// (`AppTokens.focusRing`, width 2) - drawn by `ContextMenuFocus` for a
/// region that owns its own focus node, and by the same-shaped rings on
/// `AppIconButton`/`AppInput`/the button themes. All of those wrap a single
/// control; only the bug this file guards wraps the whole scrollable list.
Finder _focusRings(AppTokens tokens) => find.byWidgetPredicate((widget) {
  if (widget is! DecoratedBox) return false;
  final decoration = widget.decoration;
  if (decoration is! BoxDecoration) return false;
  final border = decoration.border;
  if (border is! Border) return false;
  return border.top.color == tokens.focusRing && border.top.width == 2;
});

void main() {
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  for (final width in _widths) {
    testWidgets(
      'at ${width.toInt()}px, tabbing through the rail never rings the '
      'whole list, only a row-sized stop',
      (tester) async {
        final fixture = await _pumpRailOnly(tester, width);
        const tokens = AppTokens.dark;

        for (var i = 0; i < 40; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();

          for (final element in _focusRings(tokens).evaluate()) {
            final rect = tester.getRect(find.byWidget(element.widget));
            expect(
              rect.height,
              lessThan(100),
              reason:
                  'a ring this tall ($rect) at tab $i is the whole rail lit '
                  'up, not a row or a glyph',
            );
          }
        }

        await teardownFixture(tester, fixture.container, fixture.db);
      },
    );

    testWidgets(
      'at ${width.toInt()}px, the context-menu key still opens Create '
      'channel/category from a real add-glyph stop',
      (tester) async {
        final fixture = await _pumpRailOnly(tester, width);

        await _tabUntil(tester, _isAddChannelGlyph);
        expect(find.text('Create channel'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pumpAndSettle();

        expect(find.text('Create channel'), findsOneWidget);
        expect(find.text('Create category'), findsOneWidget);

        await teardownFixture(tester, fixture.container, fixture.db);
      },
    );
  }
}
