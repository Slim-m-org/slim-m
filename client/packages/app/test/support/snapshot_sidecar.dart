// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `<name>.json` written beside every snapshot PNG, so the review bundle
/// reads the test, viewport and theme a picture came from instead of parsing
/// its file name.
///
/// Nothing in it changes between two runs of the same code: no timestamp, no
/// absolute path.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper files a stack passes through on its way to the test that asked for the picture.
const _plumbing = {
  'ui_snapshot_support.dart',
  'ui_snapshot_fixture.dart',
  'snapshot_sidecar.dart',
  'real_shadows.dart',
};

final _frameFile = RegExp(r'\((file:///[^)]+?\.dart):\d+:\d+\)');

/// The sidecar text for a picture of [capture] size, called while the frame it describes is still mounted.
///
/// The app's theme is looked for under [root].
String snapshotSidecar(
  WidgetTester tester,
  String name, {
  required Element root,
  required Size capture,
  required StackTrace stack,
}) {
  final view = tester.view;
  return encodeSnapshotSidecar(
    name: name,
    test: snapshotTestFile(stack.toString(), Directory.current.path),
    description: tester.testDescription,
    viewport: view.physicalSize / view.devicePixelRatio,
    capture: capture,
    brightness: _themeBrightness(root),
  );
}

/// The stable JSON for one picture; [viewport] is the window, [capture] the boundary the PNG was cut from.
String encodeSnapshotSidecar({
  required String name,
  required String? test,
  required String description,
  required Size viewport,
  required Size capture,
  required Brightness? brightness,
}) =>
    '${const JsonEncoder.withIndent('  ').convert({'name': name, 'test': test, 'description': description, 'width': _logical(viewport.width), 'height': _logical(viewport.height), 'captureWidth': _logical(capture.width), 'captureHeight': _logical(capture.height), 'brightness': brightness?.name})}\n';

/// The package-relative path of the test that asked for the picture.
///
/// A `_test.dart` frame wins; a case registered from a helper library has none, so its first non-plumbing frame under `test/` stands in.
String? snapshotTestFile(String stack, String packageRoot) {
  final files = [
    for (final m in _frameFile.allMatches(stack))
      _relative(Uri.parse(m.group(1)!).toFilePath(), packageRoot),
  ].where((f) => f.startsWith('test/')).toList();
  for (final f in files) {
    if (f.endsWith('_test.dart')) return f;
  }
  for (final f in files) {
    if (!_plumbing.contains(f.split('/').last)) return f;
  }
  return null;
}

String _relative(String path, String root) {
  final prefix = root.endsWith('/') ? root : '$root/';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

num _logical(double value) => value == value.roundToDouble()
    ? value.round()
    : (value * 100).round() / 100;

/// The app's own theme is the first one under the boundary, above any a widget nests for itself.
///
/// A boundary mounted inside the app has none below it, so its nearest ancestor's is read.
Brightness? _themeBrightness(Element root) {
  Brightness? found;
  void visit(Element element) {
    if (found != null) return;
    final widget = element.widget;
    if (widget is Theme) {
      found = widget.data.brightness;
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return found ?? root.findAncestorWidgetOfExactType<Theme>()?.data.brightness;
}
