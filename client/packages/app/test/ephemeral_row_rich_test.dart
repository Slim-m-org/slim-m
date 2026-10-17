// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's private answer with a file and an embed renders both, and
/// reporting it sends the text the card showed, since the server kept none.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/attachment_bytes.dart';
import 'package:slimm_app/src/providers/ephemeral_messages.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/ephemeral_report.dart';
import 'package:slimm_app/src/widgets/ephemeral_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _file = api.Attachment(
  id: 'f1',
  filename: 'balance.pdf',
  contentType: 'application/pdf',
  size: 1800,
);

api.EphemeralMessage _message({String content = 'you have 500 chips'}) =>
    api.EphemeralMessage(
      id: 'e1',
      channelId: 'c1',
      authorId: 'bot-1',
      authorDisplayName: 'Helper',
      content: content,
      inReplyToId: 'm1',
      createdAt: 1,
      attachments: const [_file],
      embeds: const [
        api.Embed(
          title: 'Balance',
          description: 'Updated a minute ago',
          fields: [api.EmbedField(name: 'Chips', value: '500', inline: true)],
        ),
      ],
    );

Future<List<http.Request>> _pump(
  WidgetTester tester,
  api.EphemeralMessage message,
) async {
  final sent = <http.Request>[];
  final client = MockClient((request) async {
    sent.add(request);
    return http.Response(
      jsonEncode({'id': 'r1'}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      attachmentBytesProvider(
        _file.id,
      ).overrideWith((ref) async => Uint8List.fromList(const [1, 2, 3])),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(ephemeralMessagesProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final shown = ref.watch(channelEphemeralMessagesProvider('c1'));
              return Column(
                children: [
                  for (final m in shown)
                    EphemeralRow(
                      message: m,
                      knownUsernames: const {},
                      knownRoleNames: const {},
                      customEmoji: const {},
                      onDismiss: () {},
                      onReport: () =>
                          unawaited(reportEphemeralMessage(context, m)),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  events.add(api.MessageEphemeral(channelId: 'c1', message: message));
  await tester.pumpAndSettle();
  return sent;
}

void main() {
  testWidgets('a private answer draws its embed and its file', (tester) async {
    await _pump(tester, _message());

    expect(find.text('you have 500 chips'), findsOneWidget);
    expect(find.text('Balance'), findsOneWidget);
    expect(find.text('Updated a minute ago'), findsOneWidget);
    expect(find.text('Chips'), findsOneWidget);
    expect(find.text('balance.pdf'), findsOneWidget);
    expect(find.textContaining('Only you can see this'), findsOneWidget);
  });

  testWidgets('an embed alone is a whole private answer', (tester) async {
    await _pump(tester, _message(content: ''));

    expect(find.text('Balance'), findsOneWidget);
    expect(find.text('you have 500 chips'), findsNothing);
  });

  testWidgets('reporting sends the card text, the bot and the channel', (
    tester,
  ) async {
    final sent = await _pump(tester, _message());

    await tester.tap(find.widgetWithText(AppButton, 'Report'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'it asked for a password');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Report').last);
    await tester.pumpAndSettle();

    final post = sent.singleWhere((r) => r.url.path == '/reports');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['subject_kind'], 'ephemeral_message');
    expect(body['subject_id'], 'e1');
    expect(body['channel_id'], 'c1');
    expect(body['author_id'], 'bot-1');
    expect(body['reason'], 'it asked for a password');
    final snapshot = body['snapshot'] as String;
    expect(snapshot, contains('you have 500 chips'));
    expect(snapshot, contains('Balance'));
    expect(snapshot, contains('Chips: 500'));
    expect(snapshot, contains('balance.pdf'));
  });

  test('a snapshot never outgrows what the server accepts', () {
    final long = _message(content: 'x' * 5000);
    expect(ephemeralSnapshot(long).length, maxEphemeralSnapshotChars);
  });
}
