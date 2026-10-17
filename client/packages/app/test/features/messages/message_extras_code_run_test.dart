// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared code-block output's client cache: a live `code_run.changed` frame
/// makes a run someone else triggered visible to everyone watching, keyed by
/// block, and a REST fetch rehydrates it - the same in-memory shape reactions
/// use (see `message_extras_thread_live_test.dart`).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

api.CodeRun _run(int block, String output, {bool ok = true}) => api.CodeRun(
  blockIndex: block,
  moduleId: 'code-exec',
  command: 'run',
  ok: ok,
  output: output,
  ranBy: 'u1',
  ranAt: 1700000000000,
);

void main() {
  test(
    'a live code_run.changed frame shows a run to everyone, keyed by block',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);
      final controller = container.read(messageExtrasProvider.notifier);

      expect(controller.extrasFor('m1').codeRuns, isEmpty);

      events.add(
        api.CodeRunChanged(
          channelId: 'c1',
          messageId: 'm1',
          run: _run(0, '42'),
        ),
      );
      await _settle();

      final runs = controller.extrasFor('m1').codeRuns;
      expect(runs, hasLength(1));
      expect(runs.first.blockIndex, 0);
      expect(runs.first.output, '42');
    },
  );

  test(
    'a re-run of the same block replaces its entry rather than appending',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);
      final controller = container.read(messageExtrasProvider.notifier);

      events.add(
        api.CodeRunChanged(channelId: 'c1', messageId: 'm1', run: _run(0, '1')),
      );
      events.add(
        api.CodeRunChanged(channelId: 'c1', messageId: 'm1', run: _run(1, 'a')),
      );
      events.add(
        api.CodeRunChanged(channelId: 'c1', messageId: 'm1', run: _run(0, '2')),
      );
      await _settle();

      final runs = controller.extrasFor('m1').codeRuns;
      expect(runs, hasLength(2), reason: 'block 0 replaced, block 1 kept');
      expect(runs.map((r) => r.blockIndex), [0, 1]);
      expect(runs.firstWhere((r) => r.blockIndex == 0).output, '2');
    },
  );

  test(
    'a REST fetch rehydrates code_runs; a bare live frame cannot clobber it',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);
      final controller = container.read(messageExtrasProvider.notifier);

      controller.applyMessages([
        api.Message(
          id: 'm1',
          channelId: 'c1',
          authorId: 'a1',
          authorDisplayName: 'Alice',
          seq: 1,
          content: '```js\nx\n```',
          createdAt: 0,
          editedAt: null,
          codeRuns: [_run(0, 'fetched')],
        ),
      ]);
      expect(controller.extrasFor('m1').codeRuns, hasLength(1));

      // A live message frame is built from a bare DTO with no code_runs; it must not erase the result already known.
      events.add(
        const api.MessageCreated(
          api.Message(
            id: 'm1',
            channelId: 'c1',
            authorId: 'a1',
            authorDisplayName: 'Alice',
            seq: 2,
            content: '```js\nx\n```',
            createdAt: 0,
            editedAt: null,
          ),
        ),
      );
      await _settle();

      expect(controller.extrasFor('m1').codeRuns, hasLength(1));
      expect(controller.extrasFor('m1').codeRuns.first.output, 'fetched');
    },
  );

  test(
    'a code_runs.cleared frame drops every run, unlike a bare edited frame',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);
      final controller = container.read(messageExtrasProvider.notifier);

      events.add(
        api.CodeRunChanged(channelId: 'c1', messageId: 'm1', run: _run(0, '2')),
      );
      events.add(
        api.CodeRunChanged(channelId: 'c1', messageId: 'm1', run: _run(1, 'x')),
      );
      await _settle();
      expect(controller.extrasFor('m1').codeRuns, hasLength(2));

      events.add(const api.CodeRunsCleared(channelId: 'c1', messageId: 'm1'));
      await _settle();

      expect(
        controller.extrasFor('m1').codeRuns,
        isEmpty,
        reason: 'an edit must not leave an older run attached to new code',
      );
    },
  );
}
