// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reaction broadcast must apply even when the cached tallies are a covariant `List<Never>`,
/// which made firstWhere's orElse throw on iOS (2026-10-22).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/live_events.dart';

void main() {
  test('a reactions change applies over an untyped empty tally list', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(container.dispose);
    final extras = container.read(messageExtrasProvider.notifier);
    extras.applyMessage(
      const api.Message(
        id: 'm1',
        channelId: 'c1',
        authorId: 'u1',
        authorDisplayName: 'Ada',
        seq: 1,
        content: 'hi',
        createdAt: 1,
        editedAt: null,
        reactions: <Never>[],
      ),
    );

    events.add(
      const api.ReactionsChanged(
        channelId: 'c1',
        messageId: 'm1',
        reactions: [api.ReactionTally(emoji: '\u{1F44D}', count: 2)],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final reactions = container.read(messageExtrasProvider)['m1']!.reactions;
    expect(reactions.single.count, 2);
    expect(reactions.single.reacted, isFalse);
  });
}
