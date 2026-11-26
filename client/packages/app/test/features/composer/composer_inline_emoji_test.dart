// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A completed custom `:name:` in the channel composer is drawn as its emoji in place, with no preview bar, and sends as the canonical text.
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
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
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

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

const _owner = ' :hehe:  :bruins:  :extreme_teamwork: lets gooooo :joy: ';
const _joy = '\u{1F602}';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<List<String>> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1280, 700);
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
      customEmojiImageProvider.overrideWith((ref, id) => _png),
      mockApiOverride((request) async {
        final path = request.url.path;
        if (path == '/me') {
          return _json({
            'id': 'bob',
            'username': 'bob',
            'display_name': 'Bob',
            'created_at': 0,
            'permissions': 0,
          });
        }
        if (path == '/emoji') {
          return _json([
            for (final n in ['hehe', 'bruins', 'extreme_teamwork'])
              {'id': 'e-$n', 'name': n, 'uploader_id': null, 'created_at': 0},
          ]);
        }
        if (request.method == 'POST' && path == '/channels/c1/messages') {
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
        theme: buildTheme(
          brightness,
          brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
        ).copyWith(platform: TargetPlatform.linux),
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

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Finder get _editable => find.descendant(
  of: find.byWidgetPredicate((w) => w is Composer),
  matching: find.byWidgetPredicate((w) => w is EditableText),
);

Finder get _inField => find.descendant(
  of: _editable,
  matching: find.byWidgetPredicate((w) => w is CustomEmojiImage),
);

Finder get _anywhere => find.byWidgetPredicate((w) => w is CustomEmojiImage);

EditableTextState _state(WidgetTester tester) =>
    tester.state<EditableTextState>(_editable);

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

double _height(WidgetTester tester) =>
    _state(tester).renderEditable.size.height;

void main() {
  testWidgets('the owner string draws three custom emoji in the field', (
    tester,
  ) async {
    await _mount(tester);
    await _type(tester, _owner);

    expect(_inField, findsNWidgets(3));
    expect(_anywhere, findsNWidgets(3), reason: 'none outside the field');
    expect(find.byKey(const Key('composer-shortcode-preview')), findsNothing);
    expect(
      _state(tester).textEditingValue.text,
      ' :hehe:  :bruins:  :extreme_teamwork: lets gooooo $_joy ',
    );
    await _unmount(tester);
  });

  testWidgets('the sent text is the canonical shortcode form', (tester) async {
    final posted = await _mount(tester);
    await _type(tester, ':HeHe: and :bruins: :joy:');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _flush(tester);

    expect(posted, [':hehe: and :bruins: $_joy']);
    await _unmount(tester);
  });

  testWidgets('the owner string sends with the shortcodes intact', (
    tester,
  ) async {
    final posted = await _mount(tester);
    await _type(tester, _owner);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _flush(tester);

    expect(posted, [':hehe:  :bruins:  :extreme_teamwork: lets gooooo $_joy']);
    await _unmount(tester);
  });

  testWidgets('an emoji does not make the field taller than plain text', (
    tester,
  ) async {
    await _mount(tester);
    await _type(tester, 'hello there');
    final plain = _height(tester);
    tester.testTextInput.updateEditingValue(const TextEditingValue());
    await _flush(tester);

    await _type(tester, ':hehe: :bruins: x');
    expect(_inField, findsNWidgets(2));
    expect(_height(tester), closeTo(plain, 0.5));
    await _unmount(tester);
  });

  testWidgets('an unknown name stays text', (tester) async {
    await _mount(tester);
    await _type(tester, 'a :nope: b');

    expect(_anywhere, findsNothing);
    expect(_state(tester).textEditingValue.text, 'a :nope: b');
    await _unmount(tester);
  });

  testWidgets('Backspace after an emoji takes the whole shortcode', (
    tester,
  ) async {
    await _mount(tester);
    await _type(tester, 'a :hehe:');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(_state(tester).textEditingValue.text, 'a ');
    expect(_inField, findsNothing);
    await _unmount(tester);
  });

  testWidgets('the caret never rests inside the hidden characters', (
    tester,
  ) async {
    await _mount(tester);
    await _type(tester, 'a :hehe: b');
    final state = _state(tester);
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(
        selection: const TextSelection.collapsed(offset: 4),
      ),
      SelectionChangedCause.tap,
    );
    await tester.pump();

    expect(
      state.textEditingValue.selection.baseOffset,
      anyOf(2, 8),
      reason: 'snapped to an edge of :hehe:',
    );
    await _unmount(tester);
  });

  testWidgets('an emoji stays text while the keyboard composes inside it', (
    tester,
  ) async {
    await _mount(tester);
    await _type(tester, 'a :hehe: b');
    final state = _state(tester);
    tester.testTextInput.updateEditingValue(
      state.textEditingValue.copyWith(
        composing: const TextRange(start: 2, end: 6),
      ),
    );
    await tester.pump();

    expect(_inField, findsNothing);
    await _unmount(tester);
  });
}
