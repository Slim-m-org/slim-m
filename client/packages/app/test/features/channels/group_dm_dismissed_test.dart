// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving or deleting a group from the members sheet still lands when the
/// sheet is dismissed before the request answers.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/async_wait.dart';
import 'group_dm_harness.dart';

void main() {
  testWidgets('leaving still goes back to the list after the sheet closes', (
    tester,
  ) async {
    final server = await openMembersSheet(tester);
    final hold = server.holdWrites = Completer<void>();
    await tester.ensureVisible(find.text('Leave group'));
    await tester.tap(find.text('Leave group'));
    await pumpFrames(tester);
    await tester.tap(find.text('Leave group'));
    await waitUntil(
      tester,
      () => server.requests.any((r) => r.endsWith('/leave')),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester);
    expect(find.text('Leave group'), findsNothing, reason: 'the sheet is gone');

    hold.complete();
    await pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('rail'), findsOneWidget);
  });
}
