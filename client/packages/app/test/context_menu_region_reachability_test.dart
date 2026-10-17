// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The generic `ContextMenuRegion` behind every non-message context menu
/// (channel rows, DM rows): reachable by keyboard, the same guarantee
/// `context_menu_reachability_test` covers for the message region, plus the
/// one property specific to this widget.
///
/// `ownsFocusNode: false` is for a child that is already its own tab stop (an
/// `AppListRow`): it must not gain a second one in front of it, or Tab visits
/// an empty stop first and Enter there does nothing - the row's own
/// activation would sit one more Tab away than it used to.
///
/// The screen-reader long-press guarantee `context_menu_reachability_test`
/// covers for the message region is deliberately **not** extended to
/// `ownsFocusNode: false`. A first attempt merged the gesture's long-press
/// action into the row's own semantics node with `MergeSemantics`, and that
/// silently swallowed a trailing kebab's own, separate tap action - caught by
/// `message_row_thread_test.dart` and `channel_rail_channel_rows_test.dart`
/// going red for an unrelated reason, not by anything written for this fix.
/// `excludeFromSemantics` is what this widget uses instead for that case: the
/// row keeps exactly the semantics it already had, and a screen-reader user
/// reaches the menu through a connected keyboard's context-menu key, which
/// this file does cover.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/context_menu_region.dart';
import 'package:slimm_design_system/design_system.dart';

const _rowKey = Key('row');
const _kebabKey = Key('kebab');

List<Widget> _items(BuildContext context, VoidCallback close) => [
  AppMenuItem(label: 'Open channel', onTap: close),
];

/// Whether any node in the tree carries the long-press action, since a stray
/// node with nothing else to say still lives at a different id than the
/// row's own, and `find.byKey` alone would miss it.
bool _anyNodeHasLongPress(SemanticsNode node) {
  if (node.getSemanticsData().hasAction(SemanticsAction.longPress)) {
    return true;
  }
  var found = false;
  node.visitChildren((child) {
    found = found || _anyNodeHasLongPress(child);
    return true;
  });
  return found;
}

void main() {
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('ownsFocusNode: false', () {
    Future<SemanticsHandle> pumpRow(
      WidgetTester tester, {
      required VoidCallback onTap,
      required VoidCallback onKebabTap,
    }) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Center(
              child: ContextMenuRegion(
                itemsBuilder: _items,
                ownsFocusNode: false,
                child: AppListRow(
                  key: _rowKey,
                  label: 'general',
                  onTap: onTap,
                  trailingExtra: IconButton(
                    key: _kebabKey,
                    icon: const Icon(Icons.more_vert),
                    onPressed: onKebabTap,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return handle;
    }

    testWidgets('does not add a second tab stop in front of the row\'s own', (
      tester,
    ) async {
      var tapped = false;
      final handle = await pumpRow(
        tester,
        onTap: () => tapped = true,
        onKebabTap: () {},
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        tapped,
        isTrue,
        reason:
            'the first tab stop must already be the row\'s own, or Enter '
            'here would do nothing rather than open it',
      );
      handle.dispose();
    });

    testWidgets('the context-menu key still opens the menu from that stop', (
      tester,
    ) async {
      final handle = await pumpRow(tester, onTap: () {}, onKebabTap: () {});

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('Open channel'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Open channel'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a trailing kebab keeps its own, separate tap action '
        '(regression guard: MergeSemantics silently swallowed this)', (
      tester,
    ) async {
      var kebabTapped = false;
      final handle = await pumpRow(
        tester,
        onTap: () {},
        onKebabTap: () => kebabTapped = true,
      );

      final kebabNode = tester.getSemantics(find.byKey(_kebabKey));
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.tap,
          nodeId: kebabNode.id,
          viewId: tester.view.viewId,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        kebabTapped,
        isTrue,
        reason:
            'the row and the kebab must stay two distinct actionable '
            'nodes; a merge that answers this with the row\'s own tap '
            'instead is exactly the regression this guards',
      );
      handle.dispose();
    });

    testWidgets(
      'the tree carries no long-press action anywhere - the keyboard route '
      'above is what a screen-reader user takes instead',
      (tester) async {
        final handle = await pumpRow(tester, onTap: () {}, onKebabTap: () {});

        expect(
          _anyNodeHasLongPress(
            tester
                .binding
                .renderViews
                .first
                .owner!
                .semanticsOwner!
                .rootSemanticsNode!,
          ),
          isFalse,
          reason:
              'excludeFromSemantics is what keeps this false; a bare '
              'GestureDetector always publishes the action on some node, '
              'even one with no other purpose than carrying it',
        );
        handle.dispose();
      },
    );
  });

  testWidgets(
    'ownsFocusNode: true adds its own stop, for a child with none of its own',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(
            body: Center(
              child: ContextMenuRegion(
                itemsBuilder: _items,
                child: SizedBox(key: _rowKey, width: 100, height: 40),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Open channel'), findsOneWidget);
      handle.dispose();
    },
  );
}
