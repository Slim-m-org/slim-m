// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The General fields follow a rename or topic edit made elsewhere, except in a field being edited here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/widgets/channel_settings_general_section.dart';

import 'channel_management_harness.dart' show channel;
import 'channel_row_scope.dart';

void main() {
  testWidgets('an edit made elsewhere shows in a field left alone, and a field '
      'being edited keeps what was typed', (tester) async {
    await tester.pumpWidget(
      channelRowScope(
        ChannelGeneralSection(
          channel: channel('c1', 'general', topic: 'old topic'),
        ),
        (request) async => http.Response('{}', 200),
      ),
    );
    final store = await storeBehind(tester, find.text('General'));
    await emitChannel(tester, store, topic: 'old topic');

    await tester.enterText(find.bySemanticsLabel('Channel name'), 'typed');
    await emitChannel(tester, store, name: 'renamed', topic: 'new topic');

    expect(find.text('typed'), findsOneWidget, reason: 'typing is kept');
    expect(find.text('new topic'), findsOneWidget);
    expect(find.text('old topic'), findsNothing);

    await unmountRow(tester);
  });
}
