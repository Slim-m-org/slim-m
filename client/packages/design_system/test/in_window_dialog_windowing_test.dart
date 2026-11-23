// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// With Flutter's windowing flag on, which the Linux and Windows builds carry,
/// `showDialog` opens an OS window; `showInWindowDialog` must keep every dialog
/// inside the main window on both.
library;

import 'dart:async';

// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/foundation/_features.dart' as features;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _openDialog(WidgetTester tester, TargetPlatform platform) async {
  debugDefaultTargetPlatformOverride = platform;
  features.isWindowingEnabled = true;
  addTearDown(() {
    features.isWindowingEnabled = false;
    debugDefaultTargetPlatformOverride = null;
  });
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (c) {
          context = c;
          return const SizedBox.expand();
        },
      ),
    ),
  );
  unawaited(
    showInWindowDialog<void>(
      context: context,
      builder: (_) => const Text('in the main window'),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    testWidgets('${platform.name} keeps the dialog in the main window', (
      tester,
    ) async {
      await _openDialog(tester, platform);
      expect(tester.takeException(), isNull);
      expect(find.text('in the main window'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is ModalBarrier), findsWidgets);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  test('both windowing builds are covered', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(buildsWithWindowing, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(buildsWithWindowing, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(buildsWithWindowing, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}
