// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pointer sweeping over rows while a list scrolls must not flash them.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_toolbar_anchor.dart';
import 'package:slimm_app/src/widgets/hover_reveal.dart';

const _farAway = Offset(780, 580);

Widget _list(ScrollController controller, {bool reduceMotion = false}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: 40,
        itemBuilder: (context, i) => HoverReveal(
          key: ValueKey(i),
          enterDelay: kRowHoverIntent,
          calmWhileScrolling: true,
          builder: (context, hovered, menuOpen, focusWithin) {
            return MessageToolbarAnchor(
              show: hovered,
              toolbar: SizedBox(
                key: ValueKey('toolbar$i'),
                width: 60,
                height: 20,
              ),
              child: SizedBox(height: 60, child: Text('row $i')),
            );
          },
        ),
      ),
    ),
  );
}

double _opacityOf(WidgetTester tester, Finder toolbar) {
  final fades = find.ancestor(
    of: toolbar,
    matching: find.byType(FadeTransition),
  );
  return tester.widget<FadeTransition>(fades.first).opacity.value;
}

final _toolbars = find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('toolbar'),
);

Future<void> _wheel(WidgetTester tester, double dy) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: const Offset(100, 135),
      scrollDelta: Offset(0, dy),
    ),
  );
  await tester.pump();
}

void main() {
  late ScrollController controller;
  late TestGesture mouse;

  Future<void> setUpList(WidgetTester tester, {bool reduce = false}) async {
    controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_list(controller, reduceMotion: reduce));
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: _farAway);
    await tester.pump();
  }

  testWidgets(
    'a pointer that rests on a row shows its toolbar after the delay',
    (tester) async {
      await setUpList(tester);
      await mouse.moveTo(const Offset(100, 30));
      await tester.pump(kRowHoverIntent ~/ 2);
      expect(find.byKey(const ValueKey('toolbar0')), findsNothing);
      await tester.pump(kRowHoverIntent);
      await tester.pump();
      expect(find.byKey(const ValueKey('toolbar0')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, find.byKey(const ValueKey('toolbar0'))), 1);
    },
  );

  testWidgets('sweeping through a row faster than the delay lights nothing', (
    tester,
  ) async {
    await setUpList(tester);
    await mouse.moveTo(const Offset(100, 30));
    await tester.pump(kRowHoverIntent ~/ 3);
    await mouse.moveTo(_farAway);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar0')), findsNothing);
  });

  testWidgets('no hover while scrolling, then it shows once the list settles', (
    tester,
  ) async {
    await setUpList(tester);
    await mouse.moveTo(const Offset(100, 135));
    await tester.pump(kRowHoverIntent * 2);
    await tester.pump();
    expect(find.byKey(const ValueKey('toolbar2')), findsOneWidget);

    await _wheel(tester, 30);
    expect(_toolbars, findsNothing, reason: 'toolbar shown mid-scroll');
    await tester.pump(kScrollSettle ~/ 2);
    await _wheel(tester, 30);
    await tester.pumpAndSettle();
    expect(_toolbars, findsNothing, reason: 'toolbar shown mid-scroll');

    await tester.pump(kScrollSettle * 2);
    expect(_toolbars, findsNothing, reason: 'shown before the intent delay');
    await tester.pump(kRowHoverIntent * 2);
    await tester.pumpAndSettle();
    expect(_toolbars, findsOneWidget);
  });

  testWidgets('leaving fades the toolbar out, then unmounts it', (
    tester,
  ) async {
    await setUpList(tester);
    await mouse.moveTo(const Offset(100, 30));
    await tester.pump(kRowHoverIntent * 2);
    await tester.pumpAndSettle();
    final toolbar = find.byKey(const ValueKey('toolbar0'));
    await mouse.moveTo(_farAway);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(toolbar, findsOneWidget);
    expect(_opacityOf(tester, toolbar), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(toolbar, findsNothing);
  });

  testWidgets('reduce motion drops the toolbar without a fade', (tester) async {
    await setUpList(tester, reduce: true);
    await mouse.moveTo(const Offset(100, 30));
    await tester.pump(kRowHoverIntent * 2);
    await tester.pump();
    final toolbar = find.byKey(const ValueKey('toolbar0'));
    expect(toolbar, findsOneWidget);
    expect(_opacityOf(tester, toolbar), 1);
    await mouse.moveTo(_farAway);
    await tester.pump();
    await tester.pump();
    expect(toolbar, findsNothing);
  });
}
