// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The author line in a narrow docked pane: the hover toolbar's right reserve
/// must not squeeze its name, badge and time past what the line can hold.
///
/// `desktop-vs-mobile.md` law 1: the reserve follows the window width, so a
/// 360dp thread or voice-chat pane inside a wide window still gets all of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/widgets/message_hover_toolbar.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_data/data.dart';

import 'message_row_harness.dart';

const _webhook = api.UserProfile(
  id: 'webhook-1',
  username: 'alerts',
  displayName: 'Alerts Service',
  createdAt: 0,
  isWebhook: true,
);

/// Wide enough for a name beside the badge and the time, as a header should be.
const _readableHeader = 240.0;

final _longName = List.filled(40, 'wandering').join(' ');

Future<void> _pump(
  WidgetTester tester, {
  required double pane,
  Message? author,
  api.UserProfile? profile,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BatchProfilesController profiles;
  await tester.pumpWidget(
    harness(
      MediaQuery(
        data: MediaQueryData(
          size: tester.view.physicalSize,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: pane,
            child: MessageRow(
              message: author ?? message(content: 'the disk is nearly full'),
              grouped: false,
              showNewDivider: false,
              knownUsernames: const {},
              actions: noActions,
              editing: false,
              extras: MessageExtras(
                webhookUsername: profile?.isWebhook == true
                    ? 'Alerts Service'
                    : null,
              ),
              callbacks: MessageRowCallbacks(
                onRetry: noop,
                onDiscard: noop,
                onPickReaction: (_) {},
                onReactionTap: (_) {},
                onVote: (_) {},
                onSubmitEdit: (_) {},
                onCancelEdit: noop,
              ),
            ),
          ),
        ),
      ),
      overrides: [
        batchProfilesControllerProvider.overrideWith((ref) {
          profiles = BatchProfilesController(ref);
          return profiles;
        }),
      ],
    ),
  );
  if (profile != null) profiles.state = {profile.id: profile};
  await tester.pump();
}

Rect _header(WidgetTester t) =>
    t.getRect(find.byKey(MessageRowHeader.headerKey));

void main() {
  for (final pane in const [360.0, 300.0]) {
    testWidgets('a webhook author line fits a ${pane.toInt()}dp pane', (
      tester,
    ) async {
      await _pump(
        tester,
        pane: pane,
        profile: _webhook,
        author: message(
          authorId: 'webhook-1',
          authorDisplayName: 'Alerts Service',
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('WEBHOOK'), findsOneWidget);
    });

    testWidgets('a plain author line fits a ${pane.toInt()}dp pane', (
      tester,
    ) async {
      await _pump(tester, pane: pane);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a webhook author line fits a 520dp pane at 2x text', (
    tester,
  ) async {
    await _pump(
      tester,
      pane: 520,
      textScale: 2,
      profile: _webhook,
      author: message(
        authorId: 'webhook-1',
        authorDisplayName: 'Alerts Service',
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long name keeps a readable line in a 360dp pane', (
    tester,
  ) async {
    await _pump(
      tester,
      pane: 360,
      author: message(authorDisplayName: _longName),
    );
    expect(_header(tester).width, greaterThanOrEqualTo(_readableHeader));
  });

  testWidgets('a long name stops short of the toolbar in a wide pane', (
    tester,
  ) async {
    await _pump(
      tester,
      pane: 700,
      author: message(authorDisplayName: _longName),
    );
    final row = tester.getRect(find.byKey(MessageRow.hoverFillKey));
    final reserve = MessageHoverToolbar.clearance(compact: false).right;
    expect(_header(tester).right, lessThanOrEqualTo(row.right - reserve));
  });
}
