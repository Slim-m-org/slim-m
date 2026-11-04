// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/anchored_menu.dart';
import 'package:slimm_app/src/widgets/animated_menu_portal.dart';

import '../support/mid_flight_capture.dart';

const _menuKey = Key('flip-menu');
const _triggerKey = Key('flip-trigger');

Future<void> _open(WidgetTester tester, Alignment place) async {
  final controller = AnimatedMenuController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: place,
          child: AnchoredMenu(
            controller: controller,
            menu: const SizedBox(key: _menuKey, width: 160, height: 200),
            child: TextButton(
              key: _triggerKey,
              onPressed: controller.show,
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_triggerKey));
  await expectSettled(tester, 'anchored-menu-open');
}

void main() {
  testWidgets('a trigger near the top opens its menu below it', (tester) async {
    await _open(tester, Alignment.topCenter);
    final trigger = tester.getRect(find.byKey(_triggerKey));
    final menu = tester.getRect(find.byKey(_menuKey));
    expect(menu.top, greaterThanOrEqualTo(trigger.bottom));
  });

  testWidgets('a trigger near the bottom opens its menu above it', (
    tester,
  ) async {
    await _open(tester, Alignment.bottomCenter);
    final trigger = tester.getRect(find.byKey(_triggerKey));
    final menu = tester.getRect(find.byKey(_menuKey));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(menu.bottom, lessThanOrEqualTo(trigger.top));
    expect(menu.top, greaterThanOrEqualTo(0));
    expect(menu.bottom, lessThanOrEqualTo(screen.height));
  });
}
