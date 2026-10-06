// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/member_moderation_error.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/member_profile_note_field.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Wire {
  _Wire({this.getStatus = 200, this.putStatus = 200, this.initial});

  final String? initial;
  int getStatus;
  final int putStatus;
  final requests = <http.Request>[];

  Iterable<http.Request> get puts => requests.where((r) => r.method == 'PUT');
  Iterable<http.Request> get gets => requests.where((r) => r.method == 'GET');

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final status = request.method == 'GET' ? getStatus : putStatus;
    if (status != 200) return http.Response(jsonEncode({'error': 'x'}), status);
    return http.Response(
      jsonEncode({'body': initial, 'updated_at': initial == null ? null : 1}),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

ProviderContainer _container(_Wire wire) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(wire.handle),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ValueNotifier<bool>> _pump(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final shown = ValueNotifier(true);
  addTearDown(shown.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (context, show, _) => Column(
              children: [
                if (show) const MemberProfileNoteField(subjectId: 'user-maya'),
                const TextField(key: Key('elsewhere')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return shown;
}

Finder get _note => find.descendant(
  of: find.byType(MemberProfileNoteField),
  matching: find.byType(TextField),
);

Future<void> _typeInNote(WidgetTester tester, String text) async {
  await tester.tap(_note);
  await tester.pump();
  await tester.enterText(_note, text);
  await tester.pump();
}

Future<void> _blur(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('elsewhere')));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('leaving the field PUTs the trimmed note and refetches it', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(tester, _container(wire));
    expect(wire.gets, hasLength(1));

    await _typeInNote(tester, '  hello  ');
    await _blur(tester);

    expect(wire.puts, hasLength(1));
    expect(jsonDecode(wire.puts.single.body), containsPair('body', 'hello'));
    expect(wire.gets, hasLength(2), reason: 'a saved note is refetched');
  });

  testWidgets('leaving an untouched field sends nothing', (tester) async {
    final wire = _Wire();
    await _pump(tester, _container(wire));

    await tester.tap(_note);
    await tester.pump();
    await _blur(tester);

    expect(wire.puts, isEmpty);
  });

  testWidgets('a whitespace-only body clears the note rather than storing it', (
    tester,
  ) async {
    final wire = _Wire(initial: 'old');
    await _pump(tester, _container(wire));

    await _typeInNote(tester, '   ');
    await _blur(tester);

    expect(jsonDecode(wire.puts.single.body), containsPair('body', ''));
  });

  testWidgets('removing the field while it has focus still saves the note', (
    tester,
  ) async {
    final wire = _Wire();
    final shown = await _pump(tester, _container(wire));

    await _typeInNote(tester, 'hello');
    shown.value = false;
    await tester.pump();
    await tester.pump();

    expect(wire.puts, hasLength(1));
    expect(jsonDecode(wire.puts.single.body), containsPair('body', 'hello'));
  });

  testWidgets('a failed save is shown and the text stays', (tester) async {
    final wire = _Wire(putStatus: 500);
    final container = _container(wire);
    await _pump(tester, container);

    await _typeInNote(tester, 'hello');
    await _blur(tester);

    expect(
      container.read(memberModerationErrorProvider),
      contains('Could not save your note'),
    );
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('a note that fails to load says so and Retry loads it', (
    tester,
  ) async {
    final wire = _Wire(getStatus: 500);
    await _pump(tester, _container(wire));

    expect(find.text('Could not load your note.'), findsOneWidget);
    expect(tester.widget<TextField>(_note).enabled, isFalse);

    wire.getStatus = 200;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not load your note.'), findsNothing);
    expect(tester.widget<TextField>(_note).enabled, isTrue);
  });
}
