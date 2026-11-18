// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A revoked Send swaps the composer for a read-only bar while the channel
/// is open, rather than only failing the next message, and a restored one
/// brings the composer back with its draft.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_read_only_bar.dart';
import 'package:slimm_app/src/permissions.dart';

import '../../channel_history_harness.dart';

void main() {
  testWidgets('the composer follows a live change to Send messages', (
    tester,
  ) async {
    var bits = Perm.viewChannel | Perm.sendMessages;
    final harness = await mountChannel(
      tester,
      serverSeqs: const [1],
      seededSeqs: const [1],
      answerFirst: (request) async =>
          request.url.path == '/channels/c1/permissions'
          ? http.Response(
              jsonEncode({'permissions': bits}),
              200,
              headers: {'content-type': 'application/json'},
            )
          : null,
    );
    final readOnly = find.text(ComposerReadOnlyBar.message);
    final sendBar = find.byKey(const Key('composer-action-bar'));
    final input = find.byWidgetPredicate((w) => w is EditableText);
    expect(readOnly, findsNothing);
    await tester.enterText(input, 'half typed');
    await flush(tester);

    bits = Perm.viewChannel;
    harness.container.invalidate(channelPermissionsProvider);
    await flush(tester);

    expect(readOnly, findsOneWidget);
    expect(sendBar.hitTestable(), findsNothing);

    bits = Perm.viewChannel | Perm.sendMessages;
    harness.container.invalidate(channelPermissionsProvider);
    await flush(tester);

    expect(readOnly, findsNothing);
    expect(find.text('half typed'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });
}
