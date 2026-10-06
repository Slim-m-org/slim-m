// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/embed_card.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _card() => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(
      body: EmbedCard(
        embed: api.Embed(
          title: 'Build failed',
          url: 'https://example.com/build/1',
          authorName: 'ci-bot',
          authorUrl: 'https://example.com/bot',
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('Tab reaches the linked embed title and author', (tester) async {
    await tester.pumpWidget(_card());
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    final ctx = FocusManager.instance.primaryFocus?.context;
    var insideCard = false;
    ctx?.visitAncestorElements((e) {
      if (e.widget is EmbedCard) insideCard = true;
      return !insideCard;
    });
    expect(
      insideCard,
      isTrue,
      reason: 'no element inside the card took keyboard focus',
    );
  });

  testWidgets('the embed title is exposed as a link to a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_card());
    final node = tester.getSemantics(find.text('Build failed'));
    expect(node.getSemanticsData().flagsCollection.isLink, isTrue);
    handle.dispose();
  });
}
