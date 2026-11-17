// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Spaces typed at the end of a line move the caret onto the next line and
/// grow the composer, in the narrow chat beside a call, instead of hanging
/// past the right edge until a letter is typed.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_text_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// The real [ChannelScreen] at the width of the chat docked beside a call.
Future<List<String>> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(340, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);

  final posted = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      mockApiOverride((request) async {
        if (request.url.path == '/me') {
          return _json({
            'id': 'bob',
            'username': 'bob',
            'display_name': 'Bob',
            'created_at': 0,
            'permissions': 0,
          });
        }
        if (request.method == 'POST' &&
            request.url.path == '/channels/c1/messages') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          posted.add(body['content'] as String);
          return _json({
            'id': body['id'],
            'channel_id': 'c1',
            'author_id': 'bob',
            'author_display_name': 'Bob',
            'seq': 1,
            'content': body['content'],
            'created_at': 1000,
            'edited_at': null,
          });
        }
        return _json([]);
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: ChannelScreen(channelId: 'c1')),
      ),
    ),
  );
  await _flush(tester);
  await tester.tap(_editable);
  await _flush(tester);
  return posted;
}

/// Bounded, as in `channel_screen_draft_test.dart`: this screen never settles.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Drift's stream timers outlive the tree unless it is torn down here.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Finder get _field => find.byWidgetPredicate((w) => w is Composer);

Finder get _editable => find.descendant(
  of: _field,
  matching: find.byWidgetPredicate((w) => w is EditableText),
);

EditableTextState _state(WidgetTester tester) =>
    tester.state<EditableTextState>(_editable);

Rect _caret(WidgetTester tester) {
  final state = _state(tester);
  return state.renderEditable.getLocalRectForCaret(
    state.textEditingValue.selection.extent,
  );
}

double _height(WidgetTester tester) =>
    _state(tester).renderEditable.size.height;

Future<void> _type(WidgetTester tester, String typed) async {
  for (final char in typed.split('')) {
    final text = _state(tester).textEditingValue.text + char;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await tester.pump();
  }
  await _flush(tester);
}

/// Types words until the next one would wrap, so the caret sits at the edge.
Future<void> _fillFirstLine(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    final top = _caret(tester).top;
    final before = _state(tester).textEditingValue.text;
    await _type(tester, 'word ');
    if (_caret(tester).top > top) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: before.trimRight(),
          selection: TextSelection.collapsed(offset: before.trimRight().length),
        ),
      );
      await _flush(tester);
      return;
    }
  }
  fail('the first line never filled');
}

void main() {
  group('wrappingSpaces', () {
    test('keeps the length and every single space', () {
      expect(wrappingSpaces('a b'), 'a b');
      final shown = wrappingSpaces('a     b');
      expect(shown.length, 'a     b'.length);
      expect(shown, 'a     b');
    });

    test('restarts the run after a newline', () {
      expect(wrappingSpaces('  \n  '), '  \n  ');
    });
  });

  testWidgets(
    'spaces at the end of a line move the caret down and grow the field',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await _mount(tester);
      await _fillFirstLine(tester);
      final edge = _caret(tester);
      final oneLine = _height(tester);

      await _type(tester, '   ');

      expect(_caret(tester).top, greaterThan(edge.top));
      expect(_caret(tester).left, lessThan(edge.left));
      expect(_height(tester), greaterThan(oneLine));
      await _unmount(tester);
    },
  );

  testWidgets(
    'Shift+Enter with nothing after it moves the caret down and grows the field',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await _mount(tester);
      await _type(tester, 'hi');
      final first = _caret(tester);
      final oneLine = _height(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _flush(tester);

      expect(_caret(tester).top, greaterThan(first.top));
      expect(_height(tester), greaterThan(oneLine));
      await _unmount(tester);
    },
  );

  testWidgets(
    'sending still drops the trailing spaces',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final posted = await _mount(tester);
      await _type(tester, 'hello      ');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _flush(tester);

      expect(posted, ['hello']);
      await _unmount(tester);
    },
  );
}
