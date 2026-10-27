// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Removing a message's link-preview cards: who may, that the removal is
/// one way in memory, and the X on a card that sends the request.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_card.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'message_row_harness.dart';

const _me = 'me';
const _tokens = api.TokenPair(
  userId: _me,
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

api.Message _wire({bool removed = false}) => api.Message.fromJson({
  'id': 'm1',
  'channel_id': 'c1',
  'author_id': _me,
  'author_display_name': 'Me',
  'seq': 1,
  'content': 'see https://example.com/a',
  'created_at': 1,
  'link_previews_removed': removed,
});

void main() {
  group('canRemoveLinkPreviews: own, or MANAGE_MESSAGES', () {
    test('the author may remove their own with no permission', () {
      expect(canRemoveLinkPreviews(message(authorId: _me), _me, 0), isTrue);
    });
    test('a moderator may remove another author', () {
      expect(
        canRemoveLinkPreviews(
          message(authorId: 'other'),
          _me,
          Perm.manageMessages,
        ),
        isTrue,
      );
    });
    test('a plain member may not remove another author', () {
      expect(
        canRemoveLinkPreviews(message(authorId: 'other'), _me, 0),
        isFalse,
      );
    });
    test('a message the server never stored has nothing to remove', () {
      expect(
        canRemoveLinkPreviews(
          message(authorId: _me, pending: true),
          _me,
          Perm.manageMessages,
        ),
        isFalse,
      );
    });
  });

  group('in-memory state', () {
    late StreamController<api.ServerEvent> events;
    late ProviderContainer container;

    setUp(() {
      events = StreamController<api.ServerEvent>.broadcast();
      container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(() {
        events.close();
        container.dispose();
      });
    });

    test('the frame sets it and a bare live edit cannot undo it', () async {
      final extras = container.read(messageExtrasProvider.notifier);
      extras.applyMessage(_wire());
      expect(extras.extrasFor('m1').linkPreviewsRemoved, isFalse);

      events.add(
        api.ServerEvent.parse(
          jsonEncode({
            'type': 'message.link_previews_removed',
            'channel_id': 'c1',
            'message_id': 'm1',
          }),
        )!,
      );
      await Future<void>.delayed(Duration.zero);
      expect(extras.extrasFor('m1').linkPreviewsRemoved, isTrue);

      extras.applyMessage(_wire());
      expect(extras.extrasFor('m1').linkPreviewsRemoved, isTrue);
    });

    test('a fetched page carrying the flag sets it', () {
      final extras = container.read(messageExtrasProvider.notifier);
      extras.applyMessages([_wire(removed: true)]);
      expect(extras.extrasFor('m1').linkPreviewsRemoved, isTrue);
    });
  });

  group('the X on a card', () {
    Future<List<http.Request>> pump(
      WidgetTester tester, {
      required int permissions,
      required String authorId,
      bool failing = false,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final requests = <http.Request>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWith(
              (ref) => SharedPreferences.getInstance(),
            ),
            liveEventsProvider.overrideWithValue(const Stream.empty()),
            sessionProvider.overrideWithValue(
              api.SessionStore(tokens: _tokens),
            ),
            myChannelPermissionsProvider.overrideWith(
              (ref, channelId) => permissions,
            ),
            linkPreviewProvider.overrideWith(
              (ref, url) => const api.LinkPreview(url: 'u', title: 'A page'),
            ),
            apiProvider.overrideWith(
              (ref) => testApi((request) async {
                requests.add(request);
                return http.Response(
                  failing ? '{"error":"nope"}' : '',
                  failing ? 500 : 204,
                  headers: {'content-type': 'application/json'},
                );
              }, session: ref.watch(sessionProvider)),
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: LinkPreviewList(
                urls: const ['https://example.com/a'],
                message: message(authorId: authorId),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return requests;
    }

    Future<void> hover(WidgetTester tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(LinkPreviewCard)));
      await tester.pump();
    }

    testWidgets('a moderator sees it on hover and a tap sends the removal', (
      tester,
    ) async {
      final requests = await pump(
        tester,
        permissions: Perm.manageMessages,
        authorId: 'other',
      );
      await hover(tester);

      expect(find.byTooltip('Remove link preview'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove link preview'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );

      expect(requests.single.method, 'DELETE');
      expect(
        requests.single.url.path,
        '/channels/c1/messages/m1/link-previews',
      );
    });

    testWidgets('a reader who may not remove it gets no X', (tester) async {
      await pump(tester, permissions: 0, authorId: 'other');
      await hover(tester);

      expect(find.byTooltip('Remove link preview'), findsNothing);
    });
  });
}
