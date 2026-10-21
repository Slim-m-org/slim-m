// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads a running canvas pane for the accessibility tests: the semantics tree as rows, focus order, painted pixels and where a finger-sized press lands.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_a11y_rig.dart';

export 'canvas_a11y_keys.dart';

/// One semantics node as a screen reader would meet it.
class SemRow {
  SemRow(this.node, this.depth, this.rect) : data = node.getSemanticsData();

  final SemanticsNode node;
  final int depth;
  final Rect rect;
  final SemanticsData data;

  String get label => data.label;
  String get hint => data.hint;
  String get value => data.value;
  String get tooltip => data.tooltip;
  ui.SemanticsFlags get flags => data.flagsCollection;

  Iterable<SemanticsAction> get actions =>
      SemanticsAction.values.where(data.hasAction);

  bool get taps => data.hasAction(SemanticsAction.tap);

  bool get isOn => flags.isToggled == ui.Tristate.isTrue;

  bool get isDisabled => flags.isEnabled == ui.Tristate.isFalse;

  /// Something a person can press, hold or type into.
  bool get isControl =>
      taps ||
      data.hasAction(SemanticsAction.longPress) ||
      data.hasAction(SemanticsAction.setText) ||
      flags.isButton ||
      flags.isTextField ||
      flags.isSlider ||
      flags.isLink;

  /// The first line of the label, which is the control's own name.
  String get name => label.split('\n').first;

  String get accessibleName =>
      [label, tooltip].where((s) => s.isNotEmpty).join(' | ');

  String describe() {
    final role = <String>[
      if (flags.isButton) 'button',
      if (flags.isTextField) 'textfield',
      if (flags.isSlider) 'slider',
      if (flags.isLink) 'link',
      if (flags.isHeader) 'header',
      if (flags.isLiveRegion) 'live',
      if (flags.scopesRoute) 'scopesRoute',
      if (flags.namesRoute) 'namesRoute',
      if (flags.isToggled == ui.Tristate.isTrue) 'toggled=on',
      if (flags.isToggled == ui.Tristate.isFalse) 'toggled=off',
      if (flags.isSelected == ui.Tristate.isTrue) 'selected',
      if (isDisabled) 'disabled',
      if (flags.isFocused == ui.Tristate.isTrue) 'focused',
      if (flags.isExpanded == ui.Tristate.isTrue) 'expanded',
      if (flags.isExpanded == ui.Tristate.isFalse) 'collapsed',
    ];
    final acts = actions
        .map((a) => a.toString().replaceFirst('SemanticsAction.', ''))
        .join(',');
    final box =
        '${rect.left.round()},${rect.top.round()} '
        '${rect.width.round()}x${rect.height.round()}';
    return '${'  ' * depth}#${node.id} [${role.join(' ')}] '
        '"${label.replaceAll('\n', ' / ')}"'
        '${value.isEmpty ? '' : ' value="$value"'}'
        '${hint.isEmpty ? '' : ' hint="$hint"'}'
        '${tooltip.isEmpty ? '' : ' tooltip="$tooltip"'}'
        ' actions=$acts @$box';
  }
}

Rect _globalRect(SemanticsNode node) {
  var rect = node.rect;
  for (SemanticsNode? n = node; n != null; n = n.parent) {
    final transform = n.transform;
    if (transform != null) rect = MatrixUtils.transformRect(transform, rect);
  }
  return rect;
}

SemanticsNode _semanticsRoot(WidgetTester tester) =>
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;

/// Every on-screen semantics node in the live tree, depth first, so a node a modal route or zero-size box dropped is absent as it is for a screen reader.
List<SemRow> semanticsRows(WidgetTester tester, {bool onlyControls = false}) {
  final rows = <SemRow>[];
  void visit(SemanticsNode node, int depth) {
    final row = SemRow(node, depth, _globalRect(node));
    final hidden = row.flags.isHidden;
    if (!hidden && !node.isInvisible) rows.add(row);
    node.visitChildren((child) {
      visit(child, hidden ? depth : depth + 1);
      return true;
    });
  }

  visit(_semanticsRoot(tester), 0);
  return onlyControls ? rows.where((r) => r.isControl).toList() : rows;
}

/// The whole live tree as one string, for "is this text anywhere" questions.
String semanticsText(WidgetTester tester) =>
    _semanticsRoot(tester).toStringDeep();

/// The rows whose name starts with [name].
List<SemRow> rowsNamed(WidgetTester tester, Pattern name) => [
  for (final row in semanticsRows(tester))
    if (row.name.startsWith(name)) row,
];

/// The tree as text, written to `$A11Y_DUMP_DIR/<name>.txt` when that is set.
String dumpSemantics(WidgetTester tester, String name) {
  final text = semanticsRows(tester).map((r) => r.describe()).join('\n');
  final dir = Platform.environment['A11Y_DUMP_DIR'];
  if (dir != null && dir.isNotEmpty) {
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.txt').writeAsStringSync('$text\n');
  }
  return text;
}

/// The pixels of [rect] as painted right now, three bytes a pixel.
Future<List<int>> pixelsOf(A11yRig rig, Rect rect) async {
  final boundary =
      rig.boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  final bytes = await rig.tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = (await image.toByteData())!;
    final bounds = rect.intersect(
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    );
    final out = <int>[];
    for (var y = bounds.top.floor(); y < bounds.bottom.ceil(); y++) {
      for (var x = bounds.left.floor(); x < bounds.right.ceil(); x++) {
        final i = (y * image.width + x) * 4;
        out.addAll([
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        ]);
      }
    }
    image.dispose();
    return out;
  });
  return bytes!;
}

bool pixelsDiffer(List<int> a, List<int> b) {
  if (a.length != b.length) return true;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return true;
  }
  return false;
}

/// The ids of every semantics node that owns a render object on the hit path at [point].
Set<int> _semanticsIdsAt(WidgetTester tester, Offset point) {
  final ids = <int>{};
  for (final entry in tester.hitTestOnBinding(point).path) {
    final target = entry.target;
    if (target is! RenderObject) continue;
    for (RenderObject? r = target; r != null; r = r.parent) {
      final id = r.debugSemantics?.id;
      if (id != null) ids.add(id);
    }
  }
  return ids;
}

/// Where a [min]-sized square around [row]'s control fails to press it: the centre and all four corners must reach the control.
List<String> touchGaps(WidgetTester tester, SemRow row, {double min = 44}) {
  final rect = row.rect;
  final area = Rect.fromCenter(
    center: rect.center,
    width: rect.width < min ? min : rect.width,
    height: rect.height < min ? min : rect.height,
  );
  const inset = 0.75;
  final probes = <String, Offset>{
    'top left': area.topLeft + const Offset(inset, inset),
    'top right': area.topRight + const Offset(-inset, inset),
    'bottom left': area.bottomLeft + const Offset(inset, -inset),
    'bottom right': area.bottomRight + const Offset(-inset, -inset),
    'centre': area.center,
  };
  final window = Offset.zero & tester.view.physicalSize;
  return [
    for (final probe in probes.entries)
      if (window.contains(probe.value) &&
          !_semanticsIdsAt(tester, probe.value).contains(row.node.id))
        probe.key,
  ];
}
