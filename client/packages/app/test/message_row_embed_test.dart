// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The embed(s) a webhook or a bot's message can carry, rendered inside the
/// message row. Split out like `message_row_poll_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

void main() {
  api.Embed embed({
    api.EmbedAccent? accent,
    List<api.EmbedField> fields = const [],
  }) => api.Embed(
    title: 'Build failed',
    description: 'main is red',
    accent: accent,
    fields: fields,
  );

  Widget rowWith(List<api.Embed> embeds) => harness(
    MessageRow(
      message: message(),
      grouped: false,
      showNewDivider: false,
      knownUsernames: const {},
      actions: noActions,
      editing: false,
      callbacks: MessageRowCallbacks(
        onRetry: () {},
        onDiscard: () {},
        onPickReaction: (_) {},
        onReactionTap: (_) {},
        onVote: (_) {},
        onSubmitEdit: (_) {},
        onCancelEdit: () {},
      ),
      extras: MessageExtras(embeds: embeds),
    ),
  );

  testWidgets('renders an embed title, description and field', (tester) async {
    await tester.pumpWidget(
      rowWith([
        embed(
          fields: const [
            api.EmbedField(name: 'Job', value: 'server-ci', inline: true),
          ],
        ),
      ]),
    );

    expect(find.text('Build failed'), findsOneWidget);
    expect(find.text('main is red'), findsOneWidget);
    expect(find.text('Job'), findsOneWidget);
    expect(find.text('server-ci'), findsOneWidget);
  });

  testWidgets('a message with no embed renders no embed card', (tester) async {
    await tester.pumpWidget(rowWith(const []));

    expect(find.text('Build failed'), findsNothing);
  });

  testWidgets('renders the footer text', (tester) async {
    await tester.pumpWidget(
      rowWith([
        const api.Embed(
          title: 'Build failed',
          footerText: 'slim-m ci',
          timestamp: 1700000000000,
        ),
      ]),
    );

    expect(find.textContaining('slim-m ci'), findsOneWidget);
  });

  testWidgets('an embed accent paints the left border, not the text colour', (
    tester,
  ) async {
    await tester.pumpWidget(rowWith([embed(accent: api.EmbedAccent.red)]));

    final stripeFinder = find.byKey(const Key('embed-accent-stripe'));
    final stripe = tester.widget<ColoredBox>(stripeFinder);
    expect(stripe.color, AppEmbedAccents.red);
    final stripeBox = tester.widget<SizedBox>(
      find.ancestor(of: stripeFinder, matching: find.byType(SizedBox)).first,
    );
    expect(stripeBox.width, greaterThan(0));

    final titleText = tester.widget<Text>(find.text('Build failed'));
    final tokens = AppTokens.light;
    expect(
      titleText.style!.color,
      isNot(AppEmbedAccents.red),
      reason: 'the accent must never become the title colour',
    );
    expect(titleText.style!.color, tokens.textPrimary);
  });
}
