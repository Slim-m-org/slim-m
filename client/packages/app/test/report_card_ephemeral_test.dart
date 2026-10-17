// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A report about a bot's private message names the bot, shows the text the
/// reporter says they saw, and offers nothing that needs a stored message.
library;

import 'package:flutter_test/flutter_test.dart';

import 'features/settings/report_card_harness.dart';

void main() {
  testWidgets('a private-message report shows the bot and the snapshot', (
    tester,
  ) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'report-1',
          subjectKind: 'ephemeral_message',
          subjectId: 'e1',
          reporterId: 'reporter-1',
          channelId: 'channel-1',
          snapshot: 'send me your password',
          subjectAuthorId: 'bot-1',
        ),
      ],
      profiles: {'reporter-1': 'Alice', 'bot-1': 'Helper'},
    );

    expect(find.text('Reported private message'), findsOneWidget);
    expect(find.text('Reported bot'), findsOneWidget);
    expect(find.text('Helper'), findsOneWidget);
    expect(find.text('send me your password'), findsOneWidget);
    expect(find.textContaining('kept no copy'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('it has no message to jump to or delete', (tester) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'report-1',
          subjectKind: 'ephemeral_message',
          subjectId: 'e1',
          reporterId: 'reporter-1',
          channelId: 'channel-1',
          snapshot: 'hi',
          subjectAuthorId: 'bot-1',
          channelPermissions: -1,
        ),
      ],
      profiles: {'reporter-1': 'Alice', 'bot-1': 'Helper'},
    );

    expect(find.text('Jump to message'), findsNothing);
    expect(find.text('Delete message'), findsNothing);
  });
}
