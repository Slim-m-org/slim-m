// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Is everything painted on the current frame also in its semantics tree?
///
/// The e2e harness went red for two days (#1126) on a button that was on
/// screen, enabled and clickable with a mouse, yet absent from the semantics
/// tree: a dialog route had swallowed it into its own label and dropped its
/// tap action. A screen reader user hit the same wall, and nothing in the
/// suite looked at the tree. This is the shared check behind the overlay and
/// screen gates: each visible text appears in a node that is not the route
/// scope itself, and each enabled button has a node that taps.
///
/// A finding names the widget and why the tree lost it. Fix the widget, never
/// the check: a control only a mouse can reach is a bug, whatever the reason.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

String _problem(String kind, String label, String why) =>
    '$kind "$label": $why';

/// Every node in the live semantics tree, hidden (off-screen) ones included:
/// what a screen reader can walk to, independent of which render object a
/// node happens to hang off.
List<SemanticsNode> _allNodes(WidgetTester tester) {
  final nodes = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    nodes.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  // Any node will do as a starting point; the root is however far up it goes.
  var root = tester.getSemantics(find.byType(MaterialApp));
  while (root.parent != null) {
    root = root.parent!;
  }
  visit(root);
  return nodes;
}

/// The nodes whose label or tooltip carries [text], on its own or merged
/// with siblings. A `Tooltip` announces through the tooltip slot, not the
/// label, and that is how `IconButton(tooltip:)` names itself.
Iterable<SemanticsNode> _naming(List<SemanticsNode> nodes, String text) =>
    nodes.where((n) => n.label.contains(text) || n.tooltip.contains(text));

/// Whether [element] sits under a deliberate exclusion: an `ExcludeSemantics`
/// or a `Semantics(excludeSemantics: true)` ancestor, the way a button hides
/// its visual label behind its semantic one, or an avatar hides its initials
/// behind the person's name. Those texts are meant to be absent.
bool _excluded(Element element) {
  var excluded = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is ExcludeSemantics && widget.excluding) excluded = true;
    if (widget is Semantics && widget.excludeSemantics) excluded = true;
    return !excluded;
  });
  return excluded;
}

/// Whether [element] is what a person would actually hit at its own centre:
/// on screen, not covered by a pane or a modal barrier, not an inactive
/// `IndexedStack` child, not scrolled away. A widget that fails this is still
/// built and laid out, but the frame is not showing it, so its absence from
/// the semantics tree is by design rather than a hole.
bool _visible(WidgetTester tester, Element element) {
  final box = element.renderObject;
  if (box is! RenderBox || !box.hasSize || !box.attached) return false;
  final centre = box.localToGlobal(box.size.center(Offset.zero));
  final hit = tester.hitTestOnBinding(centre);
  return hit.path.any((entry) => entry.target == box);
}

/// Every painted text and enabled button the semantics tree cannot reach, as
/// human-readable findings; empty when the frame is fully reachable.
/// [ignoreTexts] names texts that belong to the test scaffold, not the
/// surface under review.
List<String> semanticsProblems(
  WidgetTester tester, {
  Set<String> ignoreTexts = const {},
}) {
  final problems = <String>[];
  final nodes = _allNodes(tester);

  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    // Judged by what it announces, not what it shows: a counter's "0/2000" reads as "2000 characters remaining".
    final text = (widget.semanticsLabel ?? widget.data)?.trim();
    if (text == null || text.isEmpty || ignoreTexts.contains(text)) continue;
    if (_excluded(element) || !_visible(tester, element)) continue;
    final naming = _naming(nodes, text).toList();
    if (naming.isEmpty) {
      problems.add(_problem('text', text, 'appears in no semantics node'));
    } else if (naming.every(
      (n) => n.getSemanticsData().flagsCollection.scopesRoute,
    )) {
      problems.add(
        _problem('text', text, 'was merged into the route node itself'),
      );
    }
  }

  void checkButton(String kind, String label) {
    final naming = _naming(nodes, label);
    if (naming.isEmpty) {
      problems.add(_problem(kind, label, 'appears in no semantics node'));
    } else if (!naming.any(
      (n) => n.getSemanticsData().hasAction(SemanticsAction.tap),
    )) {
      problems.add(_problem(kind, label, 'has a node, but none of them taps'));
    }
  }

  for (final element in find.byType(AppButton).evaluate()) {
    final button = element.widget as AppButton;
    if (button.disabled || button.onPressed == null) continue;
    if (!_visible(tester, element)) continue;
    checkButton('AppButton', button.semanticLabel ?? button.label);
  }
  for (final element in find.byType(AppIconButton).evaluate()) {
    final button = element.widget as AppIconButton;
    if (button.onPressed == null) continue;
    if (!_visible(tester, element)) continue;
    checkButton('AppIconButton', button.semanticLabel);
  }
  for (final element in find.byType(IconButton).evaluate()) {
    final button = element.widget as IconButton;
    if (button.onPressed == null || button.tooltip == null) continue;
    if (!_visible(tester, element)) continue;
    checkButton('IconButton', button.tooltip!);
  }
  return problems;
}

/// The route node a modal surface names itself with: `scopesRoute` and
/// `namesRoute` set and [label] as its name, or null when the surface is not
/// exposed as a dialog at all.
SemanticsNode? namedRoute(WidgetTester tester, String label) {
  for (final node in _allNodes(tester)) {
    final flags = node.getSemanticsData().flagsCollection;
    if (flags.scopesRoute && flags.namesRoute && node.label == label) {
      return node;
    }
  }
  return null;
}

/// Whether any node a screen reader can walk to announces [text].
bool announces(WidgetTester tester, String text) =>
    _naming(_allNodes(tester), text).isNotEmpty;
