// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A faded-out label still reaches a screen reader, and the e2e harness that
/// reads the accessibility tree, since it only hides a caption visually.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/media_label.dart';

void main() {
  testWidgets('a hidden RevealFade keeps its child in the semantics tree', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: RevealFade(revealed: false, child: Text('Alice')),
      ),
    );

    final render = tester.renderObject<RenderAnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(render.alwaysIncludeSemantics, isTrue);
  });
}
