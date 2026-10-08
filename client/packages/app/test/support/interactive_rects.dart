// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where every tappable thing on screen really is, read from the semantics
/// tree, so a geometry test covers whatever a screen draws rather than a list
/// of widgets someone remembered to name.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class Tappable {
  const Tappable(this.label, this.rect);

  final String label;
  final Rect rect;

  @override
  String toString() => '$label $rect';
}

/// Every visible semantics node that can be tapped, in global coordinates.
/// A node that merges into its parent is skipped: the parent is the target.
List<Tappable> tappables(WidgetTester tester) {
  var root = tester.getSemantics(find.byType(MaterialApp).first);
  while (root.parent != null) {
    root = root.parent!;
  }
  final found = <Tappable>[];
  void visit(SemanticsNode node, Matrix4 parent) {
    final transform = node.transform == null
        ? parent
        : (parent.clone()..multiply(node.transform!));
    if (!node.isInvisible && !node.isMergedIntoParent) {
      final data = node.getSemanticsData();
      if (data.hasAction(SemanticsAction.tap)) {
        found.add(
          Tappable(
            data.label.isEmpty ? '(unlabelled)' : data.label,
            MatrixUtils.transformRect(transform, node.rect),
          ),
        );
      }
    }
    node.visitChildren((child) {
      visit(child, transform);
      return true;
    });
  }

  visit(root, Matrix4.identity());
  return found;
}

/// Pairs of tappables that partly cover each other. One that fully contains
/// another is a parent and its child, which is fine.
List<String> partialOverlaps(List<Tappable> all) {
  bool contains(Rect a, Rect b) =>
      a.inflate(0.5).expandToInclude(b) == a.inflate(0.5);
  final out = <String>[];
  for (var i = 0; i < all.length; i++) {
    for (var j = i + 1; j < all.length; j++) {
      final a = all[i].rect;
      final b = all[j].rect;
      final inter = a.intersect(b);
      if (inter.width <= 1 || inter.height <= 1) continue;
      if (contains(a, b) || contains(b, a)) continue;
      out.add('${all[i]} overlaps ${all[j]}');
    }
  }
  return out;
}

/// Visible text that a tappable partly covers: a control printed over a label.
/// Text inside a [content] rect is skipped: canvas content can be panned under
/// any fixed control, so where it sits is not a layout the screen chose.
List<String> textUnderTappables(
  WidgetTester tester,
  List<Tappable> all, {
  List<Rect> content = const [],
}) {
  final out = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final text = (element.widget as Text).data;
    if (text == null || text.trim().isEmpty) continue;
    final box = element.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (content.any((c) => c.inflate(1).contains(rect.center))) continue;
    for (final t in all) {
      final inter = rect.intersect(t.rect);
      if (inter.width <= 1 || inter.height <= 1) continue;
      final inside =
          t.rect.inflate(1).contains(rect.topLeft) &&
          t.rect.inflate(1).contains(rect.bottomRight);
      if (!inside) out.add('"$text" $rect is covered by $t');
    }
  }
  return out;
}
