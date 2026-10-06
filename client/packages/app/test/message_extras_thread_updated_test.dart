// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/message_extras.dart';

void main() {
  test('ThreadUpdated keeps appSurface and call on the parent', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(container.dispose);
    final controller = container.read(messageExtrasProvider.notifier);

    controller.applyMessages([
      const api.Message(
        id: 'm1',
        channelId: 'c1',
        authorId: 'a',
        authorDisplayName: 'A',
        seq: 1,
        content: '',
        createdAt: 0,
        editedAt: null,
        appSurface: api.AppSurface(moduleId: 'mod', command: 'cmd'),
        call: api.CallRecord(outcome: api.CallOutcome.answered, durationMs: 5),
      ),
    ]);
    expect(controller.extrasFor('m1').appSurface, isNotNull);
    expect(controller.extrasFor('m1').call, isNotNull);

    events.add(
      const api.ThreadUpdated(
        channelId: 'c1',
        parentMessageId: 'm1',
        threadChannelId: 't1',
        replyCount: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.extrasFor('m1').threadChannelId, 't1');
    expect(controller.extrasFor('m1').appSurface, isNotNull);
    expect(controller.extrasFor('m1').call, isNotNull);
  });
}
