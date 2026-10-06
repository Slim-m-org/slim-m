// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message row's menu, thread chip, edited marker, edit mode and reaction
/// chips at a phone, a narrow-desktop and a desktop width in both themes. PNGs
/// are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts each
/// scene lays out without overflow.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';
import 'ui_snapshot_support.dart';

MessageActions _actions({required bool own}) => MessageActions(
  canReply: true,
  onReply: noop,
  canEdit: own,
  onEdit: noop,
  canDelete: own,
  onDelete: noop,
  canManagePins: true,
  pinned: false,
  onTogglePin: noop,
  canReport: !own,
  onReport: noop,
  canBlockAuthor: !own,
  onBlockAuthor: noop,
  canOpenThread: true,
  onOpenThread: noop,
  canCopyLink: true,
  onCopyLink: noop,
  canForward: true,
  onForward: noop,
  canSave: true,
  onSave: noop,
  onStartSelecting: own ? noop : null,
);

const _thumbs = '\u{1F44D}';
const _heart = '\u{2764}';

Widget _row(
  String id,
  String content, {
  bool own = false,
  bool editing = false,
  bool grouped = false,
  int? editedAt,
  int? threadReplies,
  int? threadUnread,
  Duration threadAgo = const Duration(hours: 2),
  List<api.ReactionSummary> reactions = const [],
  VoidCallback? onHistory,
}) => MessageRow(
  key: ValueKey(id),
  message: message(id: id, content: content, editedAt: editedAt),
  grouped: grouped,
  showNewDivider: false,
  knownUsernames: const {},
  actions: _actions(own: own),
  editing: editing,
  callbacks: MessageRowCallbacks(
    onRetry: noop,
    onDiscard: noop,
    onPickReaction: (_) {},
    onReactionTap: (_) {},
    onVote: (_) {},
    onSubmitEdit: (_) {},
    onCancelEdit: noop,
    onViewEditHistory: onHistory,
  ),
  extras: MessageExtras(
    reactions: reactions,
    threadReplyCount: threadReplies,
    threadUnreadCount: threadUnread,
    threadLastReplyAt: threadReplies == null
        ? null
        : DateTime.now().subtract(threadAgo).millisecondsSinceEpoch,
  ),
);

const _longBody =
    'the resync path replays every op after the last seen seq, so a client '
    'that was offline for an hour sends one request and applies the tail '
    'strictly in order';

/// Scene name to the rows it shows, and the row index (0-based) a menu opens on.
Map<String, ({List<Widget> rows, int? menuOn, bool own})> _scenes() => {
  'menu-other': (
    rows: [
      _row('a', 'morning, did anyone look at the canvas bug'),
      _row('b', 'yes, it was the seq ordering on resync'),
    ],
    menuOn: 1,
    own: false,
  ),
  'menu-own': (
    rows: [
      _row('a', 'morning, did anyone look at the canvas bug'),
      _row('b', 'yes, it was the seq ordering on resync', own: true),
    ],
    menuOn: 1,
    own: true,
  ),
  'thread-edited': (
    rows: [
      _row(
        'a',
        _longBody,
        editedAt: 1700000900000,
        onHistory: noop,
        threadReplies: 3,
        threadUnread: 2,
      ),
      _row(
        'b',
        'short one',
        editedAt: 1700000900000,
        threadReplies: 1,
        threadUnread: 0,
        threadAgo: const Duration(days: 1),
      ),
      _row(
        'd',
        'older thread',
        threadReplies: 12,
        threadUnread: 0,
        threadAgo: const Duration(days: 40),
      ),
      _row(
        'c',
        'edited, history closed to this viewer',
        editedAt: 1700000900000,
      ),
    ],
    menuOn: null,
    own: false,
  ),
  'edit-mode': (
    rows: [
      _row('a', 'morning, did anyone look at the canvas bug'),
      _row('b', 'yes, it was the seq ordering on resync', editing: true),
      _row('c', 'thanks, merging after ci'),
    ],
    menuOn: null,
    own: false,
  ),
  'edit-keys': (
    rows: [
      _row('a', 'morning, did anyone look at the canvas bug'),
      _row('b', 'yes, it was the seq ordering on resync', editing: true),
      _row('c', 'a continuation', editing: true, grouped: true),
    ],
    menuOn: null,
    own: false,
  ),
  'reactions': (
    rows: [
      _row(
        'a',
        'morning, did anyone look at the canvas bug',
        reactions: const [
          api.ReactionSummary(emoji: _thumbs, count: 3, reacted: true),
          api.ReactionSummary(emoji: _heart, count: 1, reacted: false),
        ],
      ),
      _row('b', 'no reactions on this one, so no add chip'),
    ],
    menuOn: null,
    own: false,
  ),
};

void main() {
  setUpAll(() async {
    await loadRealFonts();
    await loadEmojiFont();
  });

  const widths = {'390': 390.0, '800': 800.0, '1280': 1280.0};
  for (final dark in const [false, true]) {
    final mode = dark ? 'dark' : 'light';
    for (final width in widths.entries) {
      for (final scene in _scenes().entries) {
        testWidgets('${scene.key} at ${width.key} ($mode)', (tester) async {
          tester.view.physicalSize = Size(width.value, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final base = dark
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light);
          await tester.pumpWidget(
            ProviderScope(
              child: RepaintBoundary(
                key: snapshotBoundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: base.copyWith(
                    platform: width.value < 600 && scene.key != 'edit-keys'
                        ? TargetPlatform.android
                        : TargetPlatform.linux,
                  ),
                  home: Scaffold(body: ListView(children: scene.value.rows)),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final menuOn = scene.value.menuOn;
          if (menuOn != null) {
            final at =
                tester.getTopLeft(
                  find.byKey(ValueKey(String.fromCharCode(97 + menuOn))),
                ) +
                const Offset(40, 30);
            if (width.value < 600) {
              await tester.longPressAt(at);
            } else {
              await tester.tapAt(
                at,
                buttons: kSecondaryButton,
                kind: PointerDeviceKind.mouse,
              );
            }
            await tester.pumpAndSettle();
          }
          await writeSnapshot(tester, '${scene.key}-${width.key}-$mode');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
