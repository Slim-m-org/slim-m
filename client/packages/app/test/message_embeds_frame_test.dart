// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot editing its message's embeds: the `message.embeds` frame replaces
/// what a viewer holds, an edit frame without embeds keeps them, and a REST
/// page is authoritative so a clear made while away still lands.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/message_extras.dart';

api.Message _message(String content, {String? embedTitle}) =>
    api.Message.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'author_id': 'bot',
      'author_display_name': 'Bot',
      'seq': 1,
      'content': content,
      'created_at': 1,
      if (embedTitle != null)
        'embeds': [
          {'title': embedTitle},
        ],
    });

void main() {
  test('an embeds frame replaces the list, including a clear', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(container.dispose);
    final extras = container.read(messageExtrasProvider.notifier);

    extras.applyMessage(_message('status', embedTitle: 'Up'));
    events.add(
      api.ServerEvent.parse(
        jsonEncode({
          'type': 'message.embeds',
          'channel_id': 'c1',
          'message_id': 'm1',
          'embeds': [
            {'title': 'Down'},
          ],
        }),
      )!,
    );
    await Future<void>.delayed(Duration.zero);
    expect(extras.extrasFor('m1').embeds.single.title, 'Down');

    extras.applyMessage(_message('status edited'));
    expect(
      extras.extrasFor('m1').embeds.single.title,
      'Down',
      reason: 'an edit frame carries no embeds and must not clear them',
    );

    events.add(
      const api.MessageEmbedsChanged(
        channelId: 'c1',
        messageId: 'm1',
        embeds: [],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(extras.extrasFor('m1').embeds, isEmpty);
  });

  test('a REST page replaces embeds a bot cleared while away', () {
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(const Stream.empty())],
    );
    addTearDown(container.dispose);
    final extras = container.read(messageExtrasProvider.notifier);
    extras.applyMessage(_message('status', embedTitle: 'Up'));
    extras.applyMessages([_message('status')]);
    expect(extras.extrasFor('m1').embeds, isEmpty);
  });
}
