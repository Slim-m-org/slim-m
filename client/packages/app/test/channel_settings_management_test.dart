// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Channel settings screen's round trip through the API and the local
/// store: the last-channel refusal, saving name and topic, and the two
/// deletion paths. Split from `channel_management_test.dart` when it crossed
/// the file budget; the fixture both share is
/// `channel_management_harness.dart`.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';
import 'package:slimm_design_system/design_system.dart';

import 'channel_management_harness.dart';

void main() {
  group('channel settings: general and danger zone', () {
    testWidgets('the last-channel refusal explains itself rather than '
        'showing the bare server error', (tester) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (request) => request.method == 'DELETE'
              ? http.Response(
                  jsonEncode({
                    'error': "cannot delete the deployment's last channel",
                  }),
                  409,
                )
              : http.Response('{}', 200),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Manage general'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(find.textContaining('last channel here'), findsOneWidget);
      expect(
        find.textContaining("deployment's last channel"),
        findsNothing,
        reason: 'the raw server wording should not reach the screen',
      );
    });

    /// The owner: "hitting enter after typing a new channel name doesnt save
    /// it, it does nothing". Both fields had no onSubmitted at all, so the
    /// key that every other name field in this app honours did nothing here.
    testWidgets('Enter saves the name, the same as the button', (tester) async {
      final requests = <http.Request>[];
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (request) {
            requests.add(request);
            return request.method == 'PATCH'
                ? http.Response(
                    jsonEncode({
                      'id': 'c1',
                      'name': 'renamed',
                      'kind': 'text',
                      'created_at': 0,
                    }),
                    200,
                    headers: {'content-type': 'application/json'},
                  )
                : http.Response('{}', 200);
          },
        ),
      );

      await tester.tap(find.bySemanticsLabel('Manage general'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();

      await tester.enterText(find.bySemanticsLabel('Channel name'), 'renamed');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        requests.where((r) => r.method == 'PATCH').map((r) => r.url.path),
        ['/channels/c1'],
      );
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Enter on an unchanged name sends nothing at all', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (request) {
            requests.add(request);
            return http.Response('{}', 200);
          },
        ),
      );

      await tester.tap(find.bySemanticsLabel('Manage general'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
    });

    testWidgets('saving the name and topic sends a PATCH and stays open, '
        'unlike the old sheet which closed', (tester) async {
      final requests = <http.Request>[];
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (request) {
            requests.add(request);
            return request.method == 'PATCH'
                ? http.Response(
                    jsonEncode({
                      'id': 'c1',
                      'name': 'renamed',
                      'kind': 'text',
                      'created_at': 0,
                    }),
                    200,
                    headers: {'content-type': 'application/json'},
                  )
                : http.Response('{}', 200);
          },
        ),
      );

      await tester.tap(find.bySemanticsLabel('Manage general'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();

      await tester.enterText(find.bySemanticsLabel('Channel name'), 'renamed');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      expect(
        requests.where((r) => r.method == 'PATCH').map((r) => r.url.path),
        ['/channels/c1'],
      );
      expect(
        find.text('Channel settings'),
        findsOneWidget,
        reason: 'a save is not a delete: the screen stays open afterward',
      );
      expect(
        find.widgetWithText(AppButton, 'Save changes'),
        findsOneWidget,
        reason:
            'the button must reset to its resting label, not stay '
            '"Saving..."',
      );
      // Drains the success toast's dismiss timer so it is not pending at teardown.
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('deleting the open channel closes the screen and leaves it', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general'), channel('c2', 'random')],
            categories: const [],
            selectedId: 'c1',
            canManage: true,
            onReorder: (_) {},
          ),
          initialLocation: Routes.channel('c1'),
          handler: (request) {
            requests.add(request);
            return request.method == 'DELETE'
                ? http.Response('', 204)
                : http.Response('{}', 200);
          },
        ),
      );
      expect(find.text('channel:c1'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Manage general'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(
        requests.where((r) => r.method == 'DELETE').map((r) => r.url.path),
        ['/channels/c1'],
      );
      expect(
        find.text('Channel settings'),
        findsNothing,
        reason: 'the screen must close once the delete has landed',
      );
      expect(
        find.text('channel:c1'),
        findsNothing,
        reason: 'the pane must leave a channel that no longer exists',
      );
    });

    testWidgets('the delete dialog names its way out, and taking it deletes '
        'nothing', (tester) async {
      final requests = <http.Request>[];
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general'), channel('c2', 'random')],
            categories: const [],
            selectedId: 'c1',
            canManage: true,
            onReorder: (_) {},
          ),
          initialLocation: Routes.channel('c1'),
          handler: (request) {
            requests.add(request);
            return http.Response('{}', 200);
          },
        ),
      );

      await tester.tap(find.bySemanticsLabel('Manage general'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete channel'));
      await tester.pumpAndSettle();

      // "Keep channel", not "Cancel": next to "Delete permanently" the vaguer word is what made this dialog get copied instead of reused.
      expect(find.text('Keep channel'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);

      await tester.tap(find.text('Keep channel'));
      await tester.pumpAndSettle();

      expect(
        requests.where((r) => r.method == 'DELETE'),
        isEmpty,
        reason: 'backing out must not delete anything',
      );
      expect(
        find.text('channel:c1'),
        findsOneWidget,
        reason: 'the channel is still open',
      );
    });

    testWidgets('deleting a channel that is not open still closes the screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general'), channel('c2', 'random')],
            categories: const [],
            selectedId: 'c1',
            canManage: true,
            onReorder: (_) {},
          ),
          initialLocation: Routes.channel('c1'),
          handler: (request) => request.method == 'DELETE'
              ? http.Response('', 204)
              : http.Response('{}', 200),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Manage random'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(
        find.text('Channel settings'),
        findsNothing,
        reason: 'the screen must close for any channel, not just the open one',
      );
      expect(
        find.text('channel:c1'),
        findsOneWidget,
        reason: 'deleting another channel must not navigate away',
      );
      // Lets the closed screen's auto-dispose providers and drift's stream close run their zero-length timers.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
