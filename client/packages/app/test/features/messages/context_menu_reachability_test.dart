// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The context menu stays reachable without a mouse: by long press, including
/// to a screen reader, and by keyboard.
///
/// The menu opens on a right-click or a long press. An earlier note in this
/// repository claimed that left it with no semantic action either, so report,
/// block, edit, delete and pin were unreachable to assistive technology. That
/// was wrong, and it was wrong in the direction that matters: `GestureDetector`
/// publishes `SemanticsAction.longPress` for its own `onLongPress`, so VoiceOver
/// and TalkBack have always been able to open it.
///
/// It is worth a test anyway, because that reachability is a side effect of one
/// widget choice rather than anything stated. Swapping `GestureDetector` for a
/// `Listener`, or setting `excludeFromSemantics`, removes it silently, and the
/// only symptom is that a group of people quietly lose every message action.
///
/// The keyboard half was genuinely missing until `ContextMenuFocus`: the row
/// took no focus and no key opened the menu, so edit, delete, pin and report
/// had no keyboard route at all. The first block of tests drives the generic
/// keyboard machinery through report/block, an ungated pair on every message;
/// the tests after that drive the message-only actions (edit) the same way.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_design_system/design_system.dart';

const Key _anchor = Key('anchor');
const AppTokens _tokens = AppTokens.dark;

/// Report and block only, so the menu holds exactly the two ungated items
/// this block of tests drives.
MessageActions _reportAndBlockOnly() => MessageActions(
  canReply: false,
  onReply: () {},
  canEdit: false,
  onEdit: () {},
  canDelete: false,
  onDelete: () {},
  canManagePins: false,
  pinned: false,
  onTogglePin: () {},
  canReport: true,
  onReport: () {},
  canBlockAuthor: true,
  onBlockAuthor: () {},
  canOpenThread: false,
  onOpenThread: () {},
  canCopyLink: false,
  onCopyLink: () {},
  canForward: false,
  onForward: () {},
  canSave: false,
  onSave: () {},
);

Future<SemanticsHandle> _pump(WidgetTester tester) async {
  final handle = tester.ensureSemantics();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, _tokens),
      home: Scaffold(
        body: Center(
          child: MessageContextMenuRegion(
            content: 'hello',
            actions: _reportAndBlockOnly(),
            onAddReaction: () {},
            onPickReaction: (_) {},
            child: const SizedBox(
              key: _anchor,
              width: 120,
              height: 40,
              child: Text('a member row'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return handle;
}

/// Edit is the one action allowed here, so the menu holds exactly the two
/// ungated items plus it.
MessageActions _editOnly(VoidCallback onEdit) => MessageActions(
  canReply: false,
  onReply: () {},
  canEdit: true,
  onEdit: onEdit,
  canDelete: false,
  onDelete: () {},
  canManagePins: false,
  pinned: false,
  onTogglePin: () {},
  canReport: false,
  onReport: () {},
  canBlockAuthor: false,
  onBlockAuthor: () {},
  canOpenThread: false,
  onOpenThread: () {},
  canCopyLink: false,
  onCopyLink: () {},
  canForward: false,
  onForward: () {},
  canSave: false,
  onSave: () {},
);

Future<void> _pumpMessage(
  WidgetTester tester, {
  required VoidCallback onEdit,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, _tokens),
      home: Scaffold(
        body: Center(
          child: MessageContextMenuRegion(
            content: 'hello',
            actions: _editOnly(onEdit),
            onAddReaction: () {},
            onPickReaction: (_) {},
            child: const SizedBox(
              key: _anchor,
              width: 200,
              height: 40,
              child: Text('a message row'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Whether the keyboard-focus outline is drawn anywhere in the tree.
///
/// Matched on a border rather than on any fill, because `focusRing` and
/// `accentFill` hold the same value in every theme: a fill would be
/// indistinguishable from a selected row, which is why the design keeps focus
/// and selection apart by shape.
bool _hasFocusRing(WidgetTester tester) => tester.any(
  find.byWidgetPredicate((w) {
    if (w is! DecoratedBox || w.position != DecorationPosition.foreground) {
      return false;
    }
    final decoration = w.decoration;
    return decoration is BoxDecoration &&
        decoration.border?.top.color == _tokens.focusRing;
  }),
);

/// The label of the menu item keyboard focus is currently on, if it is on one.
String? _focusedMenuItem() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<AppMenuItem>()
    ?.label;

/// Tabs forward until [label] holds focus, so the test does not depend on how
/// many items happen to sit above it in the menu.
Future<bool> _tabTo(WidgetTester tester, String label) async {
  for (var step = 0; step < 8; step++) {
    if (_focusedMenuItem() == label) return true;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
  }
  return _focusedMenuItem() == label;
}

void main() {
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets('the region publishes a long-press action', (tester) async {
    final handle = await _pump(tester);

    final node = tester.getSemantics(find.byKey(_anchor));
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.longPress),
      isTrue,
      reason:
          'without this every action in the menu is lost to a screen '
          'reader, and nothing else would say so',
    );
    handle.dispose();
  });

  testWidgets('invoking that action really opens the menu', (tester) async {
    final handle = await _pump(tester);

    expect(find.text('More'), findsNothing);
    final node = tester.getSemantics(find.byKey(_anchor));
    tester.binding.performSemanticsAction(
      SemanticsActionEvent(
        type: SemanticsAction.longPress,
        nodeId: node.id,
        viewId: tester.view.viewId,
      ),
    );
    await tester.pumpAndSettle();

    // Publishing the action and honouring it are two different things, and a
    // published action nothing answers is worse than none.
    expect(find.text('More'), findsOneWidget);
    expect(find.text('Copy text'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the region takes focus, and shows that it has', (tester) async {
    final handle = await _pump(tester);

    expect(_hasFocusRing(tester), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(
      _hasFocusRing(tester),
      isTrue,
      reason:
          'a row a keyboard cannot land on has no route into its menu, and '
          'one that takes focus silently is a route nobody can see',
    );
    handle.dispose();
  });

  testWidgets('the context-menu key opens the menu', (tester) async {
    final handle = await _pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.text('More'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();

    expect(find.text('More'), findsOneWidget);
    expect(find.text('Copy text'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('Shift+F10 opens it too, for a keyboard with no menu key', (
    tester,
  ) async {
    final handle = await _pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.text('More'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the open menu is tabbable, and Escape closes it', (
    tester,
  ) async {
    final handle = await _pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();

    // Answered from the moment it opens, before anything inside has been tabbed to: an intent goes upward from whatever holds focus.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('More'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    // A menu that opens and cannot then be operated is half a route, so focus has to reach the items inside the overlay.
    expect(await _tabTo(tester, 'More'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('More'), findsNothing);
    handle.dispose();
  });

  testWidgets('More is opened from the keyboard and focus follows into it', (
    tester,
  ) async {
    final handle = await _pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(await _tabTo(tester, 'More'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Report message'), findsOneWidget);
    expect(
      _focusedMenuItem(),
      isNotNull,
      reason:
          'the focused row was swapped out; focus must land on the new page',
    );
    expect(await _tabTo(tester, 'Block user'), isTrue);
    handle.dispose();
  });

  testWidgets('a message action runs from the keyboard end to end', (
    tester,
  ) async {
    var edited = false;
    await _pumpMessage(tester, onEdit: () => edited = true);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_hasFocusRing(tester), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(await _tabTo(tester, 'Edit'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(edited, isTrue, reason: 'Edit was reachable but never runnable');
  });

  testWidgets('the message region keeps its long-press action', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpMessage(tester, onEdit: () {});

    final node = tester.getSemantics(find.byKey(_anchor));
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.longPress),
      isTrue,
      reason: 'the keyboard route must not cost the screen-reader one',
    );
    handle.dispose();
  });
}
