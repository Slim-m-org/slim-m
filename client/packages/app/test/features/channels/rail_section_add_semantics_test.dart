// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A section header's hover-revealed "+" is a real button to a screen reader:
/// its semantic tap opens the create sheet with no pointer anywhere near it.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';

import '../../support/async_wait.dart';
import 'channel_management_harness.dart';

void main() {
  testWidgets('the semantic tap on a hidden + opens Create a channel', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      harness(
        ChannelCategorySections(
          channels: [channel('c1', 'general')],
          categories: const [],
          selectedId: null,
          canManage: true,
          onReorder: (_) {},
        ),
        handler: (_) => http.Response('{}', 200),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('Create a channel'), findsNothing);

    final node = tester.getSemantics(
      find.bySemanticsLabel('Create a channel in Channels'),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.tap,
    );
    await pumpFrames(tester);

    expect(find.text('Create a channel'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    handle.dispose();
  });
}
