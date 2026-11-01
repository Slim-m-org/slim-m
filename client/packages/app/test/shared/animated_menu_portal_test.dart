// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `AnimatedMenuController`/`AnimatedMenuSurface`: the entrance and the
/// reversible exit every bare-`OverlayPortal` menu was missing. The exit is
/// the half a raw controller cannot have - `hide()` unmounts in one frame -
/// so these tests pin that the surface is still on screen mid-exit and gone
/// only once the reverse lands, plus the reduce-motion collapse of both.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/animated_menu_portal.dart';
import 'package:slimm_design_system/design_system.dart';

class _Host extends StatefulWidget {
  const _Host({required this.controller});

  final AnimatedMenuController controller;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: widget.controller.portal,
      overlayChildBuilder: (context) => Positioned(
        left: 20,
        top: 20,
        child: AnimatedMenuSurface(
          controller: widget.controller,
          child: const Text('menu body'),
        ),
      ),
      child: const SizedBox(width: 40, height: 40),
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  AnimatedMenuController controller, {
  bool reduceMotion = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(body: _Host(controller: controller)),
      ),
    ),
  );
}

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('menu body'),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

void main() {
  testWidgets('the menu enters with a fade rather than popping in', (
    tester,
  ) async {
    final controller = AnimatedMenuController();
    await _pump(tester, controller);

    controller.show();
    await tester.pump();
    expect(find.text('menu body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
    expect(_opacity(tester), greaterThan(0));
    expect(_opacity(tester), lessThan(1));
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
  });

  testWidgets('hide plays the exit before the portal releases', (tester) async {
    final controller = AnimatedMenuController();
    await _pump(tester, controller);
    controller.show();
    await tester.pumpAndSettle();

    controller.hide();
    await tester.pump();
    expect(
      find.text('menu body'),
      findsOneWidget,
      reason: 'mid-exit the surface is still on screen, fading',
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(_opacity(tester), lessThan(1));
    await tester.pumpAndSettle();
    expect(find.text('menu body'), findsNothing);
    expect(controller.isShowing, isFalse);
  });

  testWidgets('a re-show mid-exit keeps the menu up instead of losing it', (
    tester,
  ) async {
    final controller = AnimatedMenuController();
    await _pump(tester, controller);
    controller.show();
    await tester.pumpAndSettle();

    controller.hide();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    controller.show();
    await tester.pumpAndSettle();
    expect(find.text('menu body'), findsOneWidget);
    expect(_opacity(tester), 1);
    expect(controller.isShowing, isTrue);
  });

  testWidgets('reduce motion collapses both directions to a frame', (
    tester,
  ) async {
    final controller = AnimatedMenuController();
    await _pump(tester, controller, reduceMotion: true);

    controller.show();
    await tester.pump();
    await tester.pump();
    expect(_opacity(tester), 1, reason: 'no travel under reduce motion');

    controller.hide();
    await tester.pump();
    await tester.pump();
    expect(find.text('menu body'), findsNothing);
  });

  testWidgets('hide with nothing showing stays a harmless no-op', (
    tester,
  ) async {
    final controller = AnimatedMenuController();
    await _pump(tester, controller);
    controller.hide();
    await tester.pump();
    expect(find.text('menu body'), findsNothing);
    expect(controller.isShowing, isFalse);
  });
}
