// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tab walks the channel rail in the order it is drawn: each header, its
/// "+", then that section's channels with their kebabs, with no control a
/// stop twice and no unnamed stop. Reading order by geometry used to send
/// Tab to every header before any channel and land on the "+" twice.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/surface_registry.dart';
import '../../ui_snapshot_support.dart';

String? _name(FocusNode node) {
  String? label;
  node.context?.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Semantics && widget.properties.label != null) {
      label = widget.properties.label;
      return false;
    }
    return true;
  });
  return label;
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('Tab walks the rail top to bottom, each control once', (
    tester,
  ) async {
    tester.view.physicalSize = viewports['desktop']!;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fixture = await fixtureContainer();
    await withFixtureTeardown(tester, fixture, () async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            routerConfig: fixtureRouter(snapshotSurfaces['channel']!.route),
            builder: appChromeBuilder,
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 350));
      }

      final stops = <FocusNode>[];
      final names = <String>[];
      final tops = <double>[];
      for (var i = 0; i < 80; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focus = FocusManager.instance.primaryFocus!;
        final inRail =
            focus.context?.findAncestorWidgetOfExactType<ChannelRail>() != null;
        if (inRail && stops.isNotEmpty && focus == stops.first) break;
        if (!inRail) continue;
        stops.add(focus);
        names.add(_name(focus) ?? '(unnamed)');
        tops.add(focus.rect.center.dy);
      }

      expect(names, isNot(contains('(unnamed)')), reason: names.join('\n'));
      expect(stops.toSet().length, stops.length, reason: names.join('\n'));
      final listed = names.indexOf('Create a channel in Text');
      expect(listed, greaterThan(-1), reason: names.join('\n'));
      expect(names.sublist(listed, listed + 4), [
        'Create a channel in Text',
        'Manage Text',
        'general',
        'Manage general',
      ], reason: names.join('\n'));
      for (var i = 1; i < tops.length; i++) {
        expect(
          tops[i],
          greaterThanOrEqualTo(tops[i - 1] - 8),
          reason: '${names[i]} comes after ${names[i - 1]} but sits above it',
        );
      }
    });
  });
}
