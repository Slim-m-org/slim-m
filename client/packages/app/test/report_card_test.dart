// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The report card names what a moderator is being asked to act on: a user
/// report's subject, and either kind's reporter, both resolved through
/// `GET /users` rather than left as the raw id the wire carries, and both
/// labelled explicitly rather than left to font weight and position to say
/// which is which. See `docs/research/audit-2026-07-30/screens.md`, "The
/// report card identifies nobody".
///
/// The quick actions (jump, delete, time out, remove) are in
/// `report_card_actions_test.dart`, split out for the line budget; geometry
/// (does a long value actually fit, rather than merely render) is in
/// `report_card_layout_test.dart`, split out for the same reason.
library;

import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/reports_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'report_card_harness.dart';

void main() {
  testWidgets('a message report names its reporter, not the raw id', (
    tester,
  ) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'report-1',
          subjectKind: 'message',
          subjectId: 'message-1',
          reporterId: 'reporter-1',
          channelId: 'channel-1',
          snapshot: 'go away',
        ),
      ],
      profiles: {'reporter-1': 'Alice'},
    );

    expect(find.text('Reporter'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.textContaining('reporter-1'), findsNothing);
  });

  testWidgets('the footer date sits flush with the card content edge', (
    tester,
  ) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'report-1',
          subjectKind: 'message',
          subjectId: 'message-1',
          reporterId: 'reporter-1',
          channelId: 'channel-1',
          snapshot: 'go away',
        ),
      ],
      profiles: {'reporter-1': 'Alice'},
    );

    final card = tester.getRect(find.byType(AppCard).first);
    final date = tester.getRect(find.textContaining(RegExp(r'\d{4}')).first);
    expect(date.right, greaterThan(card.right - AppSpacing.s16 - 2));
    expect(date.right, lessThanOrEqualTo(card.right - AppSpacing.s8 + 1));
  });

  testWidgets('a user report names its subject, not the raw id', (
    tester,
  ) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'report-2',
          subjectKind: 'user',
          subjectId: 'subject-1',
          reporterId: 'reporter-2',
        ),
      ],
      profiles: {'subject-1': 'Bob', 'reporter-2': 'Carol'},
    );

    expect(
      find.text('Reported user'),
      findsOneWidget,
      reason:
          'the card title only, now that the row below it says "Subject" '
          'rather than repeating the title verbatim',
    );
    expect(find.text('Subject'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Reporter'), findsOneWidget);
    expect(find.text('Carol'), findsOneWidget);
    expect(find.textContaining('subject-1'), findsNothing);
    expect(find.textContaining('reporter-2'), findsNothing);
  });

  testWidgets(
    'a deleted account falls back honestly, for both subject and reporter',
    (tester) async {
      await pumpReports(
        tester,
        reports: [
          reportJson(
            id: 'report-3',
            subjectKind: 'user',
            subjectId: 'subject-gone',
            // Null: the server already anonymized this account.
            reporterId: null,
          ),
        ],
        // subject-gone resolves to nothing, matching a 404 on that id.
        profiles: const {},
      );

      expect(find.text('Deleted account'), findsOneWidget);
      expect(find.textContaining('a deleted account'), findsOneWidget);
      expect(find.textContaining('subject-gone'), findsNothing);
    },
  );

  /// `report_card.dart` used to leave `_busy` true on the success path only,
  /// clearing it inside the catch, and rendered `e.message` in a `SnackBar`
  /// verbatim. Both are fixed by routing through `runGuarded`: a failure now
  /// clears busy either way and shows a safe sentence that stays on the card.
  testWidgets(
    'a resolve that cannot reach the server clears busy and stays on the card',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                if (request.method == 'GET' && request.url.path == '/reports') {
                  return http.Response(
                    '[${reportJson(id: 'report-5', subjectKind: 'user', subjectId: 'u1')}]',
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.method == 'GET' && request.url.path == '/users') {
                  return http.Response(
                    '[]',
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.method == 'PATCH') {
                  throw const SocketException('connection refused');
                }
                return http.Response('{}', 404);
              }),
            );
            ref.onDispose(api.close);
            return api;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const ReportsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(AppButton, 'Resolve'));
      await tester.pumpAndSettle();
      // Disambiguated from the card's own "Resolve" button, still mounted beneath the dialog.
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.widgetWithText(AppButton, 'Resolve'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Resolve'))
            .disabled,
        isFalse,
        reason: 'the busy flag must clear on failure, not only on success',
      );
    },
  );

  testWidgets(
    'a long report body is bounded and rendered, not raw markup left to grow',
    (tester) async {
      final longSnapshot = List.generate(80, (i) => 'line $i').join('\n');
      await pumpReports(
        tester,
        reports: [
          reportJson(
            id: 'report-4',
            subjectKind: 'message',
            subjectId: 'message-2',
            reporterId: 'reporter-4',
            channelId: 'channel-1',
            snapshot: longSnapshot,
          ),
        ],
        profiles: {'reporter-4': 'Dana'},
      );

      // A RenderFlex overflow would already have failed the pump above; this confirms the bounding box itself is there.
      expect(
        find.ancestor(
          of: find.byType(SingleChildScrollView),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.constraints?.maxHeight == 160,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  /// A message report names who wrote the message, which is the other half of
  /// "name the subject before asking for an irreversible close". It could not
  /// come from `subject_id`, which is the *message's* id; the server joins the
  /// author at read time and sends it as `subject_author_id`.
  testWidgets('a message report names the reported message\'s author', (
    tester,
  ) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'r1',
          subjectKind: 'message',
          subjectId: 'm1',
          reporterId: 'u-reporter',
          subjectAuthorId: 'u-author',
          snapshot: 'go away',
        ),
      ],
      profiles: {'u-reporter': 'Reporter Rae', 'u-author': 'Author Ash'},
    );

    expect(find.text('Reported author'), findsOneWidget);
    expect(find.text('Author Ash'), findsOneWidget);
    expect(find.text('go away'), findsOneWidget);
  });

  /// A null author is not a lookup that failed. The server sends none when the
  /// message has been hard-deleted or the author anonymized, and saying so is
  /// more use to a moderator than a name that would be wrong.
  testWidgets('a message report whose author is gone says so', (tester) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'r1',
          subjectKind: 'message',
          subjectId: 'm1',
          reporterId: 'u-reporter',
          snapshot: 'go away',
        ),
      ],
      profiles: {'u-reporter': 'Reporter Rae'},
    );

    expect(find.text('Author no longer on this Space'), findsOneWidget);
  });

  testWidgets(
    'the reported snapshot renders as markdown, not the raw asterisks',
    (tester) async {
      await pumpReports(
        tester,
        reports: [
          reportJson(
            id: 'r-md',
            subjectKind: 'message',
            subjectId: 'm1',
            channelId: 'channel-1',
            snapshot: '**bold**',
          ),
        ],
      );

      final richTexts = tester.widgetList<RichText>(find.byType(RichText));
      final plainTexts = richTexts.map((r) => r.text.toPlainText());
      expect(
        plainTexts.any((t) => t.contains('**')),
        isFalse,
        reason: 'the moderator should see what the channel saw, not markup',
      );
      final bold = richTexts.where(
        (r) =>
            r.text is TextSpan &&
            (r.text as TextSpan).toPlainText().contains('bold'),
      );
      expect(bold, isNotEmpty);
    },
  );
}
