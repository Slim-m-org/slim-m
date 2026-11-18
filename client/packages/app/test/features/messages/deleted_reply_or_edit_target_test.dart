// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply or an edit whose message is deleted elsewhere while it is being
/// typed goes away and says why, rather than sending a reply to nothing or
/// dropping the edit without a word.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/channels/screens/channel_composer_area.dart';
import 'package:slimm_app/src/features/messages/widgets/message_edit_field.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_banner.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import '../../channel_history_harness.dart';

Future<StreamController<api.ServerEvent>> _mount(
  WidgetTester tester, {
  String Function(int seq)? authorFor,
}) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  await mountChannel(
    tester,
    serverSeqs: [1, 2],
    seededSeqs: [1, 2],
    syncStatus: SyncStatus.live,
    authorFor: authorFor,
    overrides: [
      myChannelPermissionsProvider.overrideWith((ref, _) => Perm.sendMessages),
      liveEventsProvider.overrideWithValue(events.stream),
    ],
  );
  return events;
}

Future<void> _pick(WidgetTester tester, String action) async {
  await tester.tapAt(
    tester.getCenter(find.text('message 2')),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await flush(tester);
  await tester.tap(find.text(action).first);
  await flush(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

const _deleted = api.MessageDeleted(channelId: 'c1', messageId: 'm2');

void main() {
  testWidgets('a reply target deleted elsewhere clears the reply and says so', (
    tester,
  ) async {
    final events = await _mount(tester);
    await _pick(tester, 'Reply');
    expect(find.byWidgetPredicate((w) => w is ReplyBanner), findsOneWidget);

    events.add(_deleted);
    await flush(tester);

    expect(find.byWidgetPredicate((w) => w is ReplyBanner), findsNothing);
    expect(find.text(replyGoneNotice), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('an edit whose message is deleted elsewhere says it was not '
      'saved', (tester) async {
    final events = await _mount(tester, authorFor: (_) => 'bob');
    await _pick(tester, 'Edit');
    expect(
      find.byWidgetPredicate((w) => w is MessageEditField),
      findsOneWidget,
    );

    events.add(_deleted);
    await flush(tester);

    expect(find.byWidgetPredicate((w) => w is MessageEditField), findsNothing);
    expect(find.text(editGoneNotice), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('another message deleted leaves the reply alone', (tester) async {
    final events = await _mount(tester);
    await _pick(tester, 'Reply');

    events.add(const api.MessageDeleted(channelId: 'c1', messageId: 'm1'));
    await flush(tester);

    expect(find.byWidgetPredicate((w) => w is ReplyBanner), findsOneWidget);
    expect(find.text(replyGoneNotice), findsNothing);
    await _unmount(tester);
  });
}
