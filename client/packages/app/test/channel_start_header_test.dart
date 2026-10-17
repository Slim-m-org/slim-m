// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The start-of-channel header: it welcomes a named channel and gives the
/// channel topic its one home in the message body, and it stays out of the way
/// where there is no such thing (a DM, whose name is a person).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_widgets.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('welcomes the channel and shows its topic when it has one', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ChannelStartHeader(
          name: 'general',
          topic: 'Everything and anything',
        ),
      ),
    );

    expect(find.text('Welcome to #general'), findsOneWidget);
    expect(find.text('Everything and anything'), findsOneWidget);
  });

  testWidgets('falls back to a start line when the channel has no topic', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(const ChannelStartHeader(name: 'design')));

    expect(find.text('Welcome to #design'), findsOneWidget);
    expect(
      find.text('This is the start of the #design channel.'),
      findsOneWidget,
    );
  });

  testWidgets('a voice channel says it is that channel\'s chat, not a DM', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const ChannelStartHeader(name: 'vc', isVoice: true)),
    );

    expect(find.text('Chat for vc'), findsOneWidget);
    expect(
      find.text('This is the start of the chat for the vc voice channel.'),
      findsOneWidget,
    );
    expect(find.textContaining('between the two of you'), findsNothing);
    expect(find.byIcon(AppIcons.voice), findsOneWidget);
  });
}
