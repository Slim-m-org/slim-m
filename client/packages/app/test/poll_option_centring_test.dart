// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A poll option's label sits in the middle of its row, not against its top.
///
/// The option is a [Stack]: a full-height track, the fill bar over it, and
/// the label row on top. A `Stack` aligns a non-positioned child to its own
/// top-start by default, so the label hugged the top edge and left the rest
/// of a touch-height row empty beneath it. Reported 2026-08-13 as "the poll
/// items text is not centered", with a screenshot.
///
/// Measured against the row's real laid-out rect rather than asserted by
/// eye: `find.text` keeps finding a label that is painted in the wrong place.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

api.Poll _poll() => const api.Poll(
  question: 'Favourite colour?',
  options: [
    api.PollOption(position: 0, label: 'Option 0', votes: 1),
    api.PollOption(position: 1, label: 'Option 1', votes: 3),
  ],
  totalVotes: 4,
  votedOption: null,
  closeAt: null,
  closed: false,
);

void main() {
  testWidgets('an option label is vertically centred in its own row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => ProviderScope(child: child!),
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: PollView(poll: _poll(), onVote: (_) {}),
        ),
      ),
    );
    await tester.pump();

    final label = find.text('Option 0');
    final row = find.ancestor(
      of: label,
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.clipBehavior == Clip.antiAlias,
      ),
    );

    final rowRect = tester.getRect(row.first);
    final labelRect = tester.getRect(label);

    expect(
      (labelRect.center.dy - rowRect.center.dy).abs(),
      lessThan(1.5),
      reason:
          'the label must sit on the row\'s own centre line, not against '
          'its top edge with the rest of the row left empty',
    );
  });
}
