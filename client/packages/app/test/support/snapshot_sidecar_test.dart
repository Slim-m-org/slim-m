// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sidecar names the right test, window and theme, and says the same thing
/// on every run.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'snapshot_sidecar.dart';

const _root = '/work/client/packages/app';

String _frame(String file) =>
    '#3      main.<anonymous closure> (file://$_root/$file:12:5)\n';

Future<Map<String, Object?>> _sidecarOf(
  WidgetTester tester, {
  required Brightness brightness,
  required Size window,
}) async {
  tester.view.physicalSize = window * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  const key = Key('boundary');
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const SizedBox.shrink(),
      ),
    ),
  );
  final boundary = tester.element(find.byKey(key));
  final text = snapshotSidecar(
    tester,
    'probe-name',
    root: boundary,
    capture: (boundary.renderObject! as RenderBox).size,
    stack: StackTrace.current,
  );
  return jsonDecode(text) as Map<String, Object?>;
}

/// A boundary mounted inside the app, as the overlay suites do.
Future<Map<String, Object?>> _sidecarOfInnerBoundary(
  WidgetTester tester,
) async {
  const key = Key('boundary');
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const RepaintBoundary(key: key, child: SizedBox.shrink()),
    ),
  );
  final boundary = tester.element(find.byKey(key));
  final text = snapshotSidecar(
    tester,
    'probe-name',
    root: boundary,
    capture: (boundary.renderObject! as RenderBox).size,
    stack: StackTrace.current,
  );
  return jsonDecode(text) as Map<String, Object?>;
}

void main() {
  group('snapshotTestFile', () {
    test(
      'picks the _test.dart frame over the helper that called the capture',
      () {
        final stack =
            _frame('test/ui_snapshot_support.dart') +
            _frame('test/snapshots/ui_snapshot_x_test.dart');
        expect(
          snapshotTestFile(stack, _root),
          'test/snapshots/ui_snapshot_x_test.dart',
        );
      },
    );

    test('falls back to the first non-plumbing helper under test/', () {
      final stack =
          _frame('test/ui_snapshot_support.dart') +
          _frame('test/features/voice/voice_snapshot_scenarios.dart');
      expect(
        snapshotTestFile(stack, _root),
        'test/features/voice/voice_snapshot_scenarios.dart',
      );
    });

    test('ignores frames outside test/ and is null when none is left', () {
      expect(snapshotTestFile(_frame('lib/src/x.dart'), _root), isNull);
      expect(
        snapshotTestFile(_frame('test/ui_snapshot_support.dart'), _root),
        isNull,
      );
    });
  });

  group('encodeSnapshotSidecar', () {
    String encode({double width = 390}) => encodeSnapshotSidecar(
      name: 'n',
      test: 'test/a_test.dart',
      description: 'd',
      viewport: Size(width, 844),
      capture: Size(width, 844),
      brightness: Brightness.dark,
    );

    test('is identical across runs', () {
      expect(encode(), encode());
    });

    test('writes whole logical pixels as integers', () {
      final json = jsonDecode(encode()) as Map<String, Object?>;
      expect(json['width'], 390);
      expect(json['height'], 844);
    });

    test('keeps a fractional width to two decimals', () {
      final json = jsonDecode(encode(width: 390.126)) as Map<String, Object?>;
      expect(json['width'], 390.13);
    });
  });

  testWidgets(
    'snapshotSidecar reads the window, theme and test of the capture',
    (tester) async {
      final json = await _sidecarOf(
        tester,
        brightness: Brightness.dark,
        window: const Size(390, 844),
      );
      expect(json['name'], 'probe-name');
      expect(json['test'], 'test/support/snapshot_sidecar_test.dart');
      expect(
        json['description'],
        'snapshotSidecar reads the window, theme and test of the capture',
      );
      expect(json['width'], 390);
      expect(json['height'], 844);
      expect(json['brightness'], 'dark');
    },
  );

  testWidgets('snapshotSidecar reports a light theme as light', (tester) async {
    final json = await _sidecarOf(
      tester,
      brightness: Brightness.light,
      window: const Size(1280, 800),
    );
    expect(json['width'], 1280);
    expect(json['brightness'], 'light');
  });

  testWidgets(
    'snapshotSidecar reads the theme above a boundary inside the app',
    (tester) async {
      final json = await _sidecarOfInnerBoundary(tester);
      expect(json['brightness'], 'dark');
    },
  );
}
