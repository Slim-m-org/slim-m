// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two things an empty thread got wrong, both found while fixing the
/// thread layout rather than reported.
///
/// The divider half is asserted against the real screen in
/// `thread_screen_test.dart`, which already has a harness that mounts it.
///
/// A thread channel is stored with an empty `name` (`Store::open_thread`
/// inserts `''`), so the channel start header's "Welcome to #$name" wording
/// had nothing to put in it and read as a channel called nothing, or called
/// "Thread". And `ThreadScreen`'s own app bar had no bottom border, the
/// same defect already fixed on `CompactChannelAppBar`: it shares
/// `surfaceBase` with the transcript at zero elevation, so there was no
/// visible boundary at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_widgets.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _wrap(Widget child, {required bool dark}) => MaterialApp(
  theme: dark
      ? buildTheme(Brightness.dark, AppTokens.dark)
      : buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('a thread start header never claims to be a named channel', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const ChannelStartHeader(name: '', isThread: true), dark: true),
    );

    expect(find.textContaining('Welcome to'), findsNothing);
    expect(
      find.textContaining('#'),
      findsNothing,
      reason: 'a thread has no channel name to render, empty or otherwise',
    );
    expect(find.text('No replies yet'), findsOneWidget);
    expect(
      find.text('Replies to the original message appear here.'),
      findsNothing,
      reason: 'the parent message above says what the thread is about',
    );
  });

  testWidgets('a real channel keeps its welcome, name and topic', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ChannelStartHeader(name: 'general', topic: 'Anything goes'),
        dark: true,
      ),
    );

    expect(find.text('Welcome to #general'), findsOneWidget);
    expect(find.text('Anything goes'), findsOneWidget);
  });

  testWidgets('a channel with no topic still explains where it is', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const ChannelStartHeader(name: 'general'), dark: true),
    );

    expect(
      find.text('This is the start of the #general channel.'),
      findsOneWidget,
    );
  });
}
