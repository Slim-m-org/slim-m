// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of the sheets and popovers that act on a message, opened
/// over the real transcript: edit history, who reacted, and forward. Each is a
/// bottom sheet below 600 and a dialog or popover from there up, so both
/// widths are captured, in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise each case asserts a clean layout.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/edit_history_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/forward_message.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_support.dart';

const _ada = 'user-ada';
const _nick = 'user-nick';
const _thumbs = '\u{1F44D}';
const _edited = 1753600000000 + 9 * 60000;

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

List<api.Message> _transcript({
  List<api.ReactionSummary> reactions = const [],
  int? editedAt,
}) => [
  reviewMessage(1, _nick, 'where did we land on the resync wording?'),
  reviewMessage(
    2,
    _ada,
    'the resync replays every op after the last seen seq, in order',
    editedAt: editedAt,
    reactions: reactions,
  ),
  reviewMessage(3, _nick, 'works for me, shipping it'),
];

/// Lets a held request answer, so no request timer outlives the case.
Future<void> _answer(ReviewScene scene, Completer<void> hold) async {
  hold.complete();
  await scene.decode(50);
}

// Edit history.

const _revisions = [
  {'content': 'the resync replays everything', 'at': 1753600000000 + 120000},
  {
    'content': 'the resync replays every op after the last seen id',
    'at': 1753600000000 + 300000,
  },
  {
    'content': 'the resync replays every op after the last seen seq, in order',
    'at': 1753600000000 + 540000,
  },
];

Future<void> _openHistory(ReviewScene scene) async {
  unawaited(showMessageEditHistorySheet(scene.context, 'c-general', 'r-2'));
  await scene.frames(3);
}

Future<void> _editHistory(
  WidgetTester tester,
  String viewport,
  String state, {
  required FutureOr<http.Response?> Function(http.Request) serve,
  SceneStep? release,
}) => captureMessages(
  tester,
  surface: 'sheet-edit-history',
  state: state,
  viewport: viewport,
  messages: _transcript(editedAt: _edited),
  serve: serve,
  act: _openHistory,
  release: release,
);

// Who reacted.

http.Response? _reactors(http.Request request, {required int count}) {
  if (!request.url.path.startsWith('/messages/r-2/reactions/')) return null;
  final after = request.url.queryParameters['after'];
  final from = after == null ? 0 : 12;
  final to = after == null ? (count > 12 ? 12 : count) : count;
  return _json({
    'users': [
      for (var i = from; i < to; i++) {'user_id': reviewReactor(i)},
    ],
    'next_cursor': after == null && count > 12 ? 'more' : null,
  });
}

Future<void> _openReactors(ReviewScene scene, {required bool phone}) async {
  final chip = find.text(_thumbs);
  if (phone) {
    await scene.tester.longPress(chip);
  } else {
    await scene.tester.tap(
      chip,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
  }
  await scene.frames(3);
}

Future<void> _reactionUsers(
  WidgetTester tester,
  String viewport,
  String state, {
  required int count,
  Completer<void>? hold,
}) => captureMessages(
  tester,
  surface: 'popover-reaction-users',
  state: state,
  viewport: viewport,
  messages: _transcript(
    reactions: [
      api.ReactionSummary(emoji: _thumbs, count: count, reacted: false),
    ],
  ),
  serve: (request) async {
    if (!request.url.path.startsWith('/messages/r-2/reactions/')) return null;
    await hold?.future;
    return _reactors(request, count: count);
  },
  act: (scene) => _openReactors(scene, phone: viewport == 'phone'),
  release: hold == null ? null : (scene) => _answer(scene, hold),
);

// Forward.

Future<void> _openForward(ReviewScene scene) async {
  final snapshot = await (await scene.store).channelSnapshot('c-general');
  final message = snapshot.firstWhere((m) => m.id == 'r-2');
  unawaited(forwardMessage(scene.context, scene.ref, message));
  await scene.frames(3);
  await scene.decode();
}

Future<void> _composeNote(ReviewScene scene) async {
  await _openForward(scene);
  // The sheet's note field sits just before its search field, both after the composer.
  final fields = find.byWidgetPredicate((w) => w is EditableText);
  await scene.tester.enterText(
    fields.at(fields.evaluate().length - 2),
    'reuse this wording in the docs?',
  );
  await scene.frames(2);
}

Future<void> _pickRefused(ReviewScene scene) async {
  await _openForward(scene);
  await scene.tester.tap(find.text('design').last);
  await scene.frames(3);
}

http.Response? _refuseSend(http.Request request) =>
    request.method == 'POST' && request.url.path.endsWith('/messages')
    ? _json({'error': 'you are not allowed to send there'}, 403)
    : null;

Future<void> _forward(
  WidgetTester tester,
  String viewport,
  String state,
  SceneStep act, {
  FutureOr<http.Response?> Function(http.Request)? serve,
}) => captureMessages(
  tester,
  surface: 'sheet-forward-message',
  state: state,
  viewport: viewport,
  messages: _transcript(),
  serve: serve,
  act: act,
);

void main() {
  setUpAll(() async {
    await loadRealFonts();
    await loadEmojiFont();
  });

  for (final viewport in reviewViewports.keys) {
    testWidgets('edit history versions at $viewport', (tester) async {
      await _editHistory(
        tester,
        viewport,
        'versions',
        serve: (r) =>
            r.url.path.endsWith('/history') ? _json(_revisions) : null,
      );
    });

    testWidgets('edit history single at $viewport', (tester) async {
      await _editHistory(
        tester,
        viewport,
        'single',
        serve: (r) =>
            r.url.path.endsWith('/history') ? _json([_revisions.last]) : null,
      );
    });

    testWidgets('edit history loading at $viewport', (tester) async {
      final hold = Completer<void>();
      await _editHistory(
        tester,
        viewport,
        'loading',
        serve: (r) async {
          if (!r.url.path.endsWith('/history')) return null;
          await hold.future;
          return _json(_revisions);
        },
        release: (scene) => _answer(scene, hold),
      );
    });

    testWidgets('reaction users list at $viewport', (tester) async {
      await _reactionUsers(tester, viewport, 'list', count: 4);
    });

    testWidgets('reaction users long list at $viewport', (tester) async {
      await _reactionUsers(tester, viewport, 'long-list', count: 20);
    });

    testWidgets('reaction users loading at $viewport', (tester) async {
      final hold = Completer<void>();
      await _reactionUsers(tester, viewport, 'loading', count: 4, hold: hold);
    });

    testWidgets('forward destinations at $viewport', (tester) async {
      await _forward(tester, viewport, 'destinations', _openForward);
    });

    testWidgets('forward compose note at $viewport', (tester) async {
      await _forward(tester, viewport, 'compose-note', _composeNote);
    });

    testWidgets('forward error at $viewport', (tester) async {
      await _forward(
        tester,
        viewport,
        'error',
        _pickRefused,
        serve: _refuseSend,
      );
    });
  }
}
