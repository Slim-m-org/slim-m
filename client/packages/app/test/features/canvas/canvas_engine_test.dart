// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasEngine]'s own lifecycle, with no widget ever pumped.
///
/// This is the property the refactor exists to prove: before it, the fetch,
/// the live-event wiring and the teardown all lived on `_CanvasPaneState`,
/// reachable only by mounting a `CanvasPane` (`canvas_pane_test.dart`,
/// `canvas_reconnect_test.dart`). Here the same engine is driven straight
/// off a bare `ProviderContainer` - `container.listen`/`container.pump`
/// stand in for a widget's own `ref.watch` and the frame that would flush
/// it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

void main() {
  test('a live frame for this channel reaches the document', () async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    final sub = container.listen(canvasEngineProvider('c1'), (_, _) {});
    addTearDown(sub.close);
    final engine = container.read(canvasEngineProvider('c1').notifier);
    engine.sync.seedFromViewport(0);
    await container.pump();

    fixture.events.add(
      api.CanvasObjectPlaced(
        channelId: 'c1',
        object: api.CanvasObject.fromJson(canvasObjectJson('a')),
      ),
    );
    await container.pump();

    expect(engine.document.knows('a'), isTrue);
  });

  test('a live frame for another channel is ignored', () async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    final sub = container.listen(canvasEngineProvider('c1'), (_, _) {});
    addTearDown(sub.close);
    final engine = container.read(canvasEngineProvider('c1').notifier);
    engine.sync.seedFromViewport(0);
    await container.pump();

    fixture.events.add(
      api.CanvasObjectPlaced(
        channelId: 'other',
        object: api.CanvasObject.fromJson(canvasObjectJson('elsewhere')),
      ),
    );
    await container.pump();

    expect(engine.document.knows('elsewhere'), isFalse);
  });

  /// The lifecycle guarantee this whole refactor is for: closing the pane
  /// (its last watcher going away) must actually stop the sync, not merely
  /// stop showing it. Mutation-checked: drop `.autoDispose` from
  /// `canvasEngineProvider` and `engine.mounted` stays true here, since
  /// nothing but that modifier ever tears the notifier down once its last
  /// listener is gone.
  test('closing the last watcher disposes the engine, and it stops applying '
      'live frames', () async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    final sub = container.listen(canvasEngineProvider('c1'), (_, _) {});
    final engine = container.read(canvasEngineProvider('c1').notifier);
    engine.sync.seedFromViewport(0);
    await container.pump();

    sub.close();
    await container.pump();

    expect(
      engine.mounted,
      isFalse,
      reason:
          'a pane with no watcher left must dispose its engine, or a '
          'closed canvas keeps syncing and relaying cursors forever',
    );
  });

  /// `.family` keyed on channel id, and `.autoDispose` evicting the entry
  /// once closed: reopening the same channel must mint a genuinely fresh
  /// engine, never resurrect the disposed one from before.
  test('reopening the same channel after closing gets a fresh engine, not the '
      'disposed one', () async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    final firstSub = container.listen(canvasEngineProvider('c1'), (_, _) {});
    final first = container.read(canvasEngineProvider('c1').notifier);
    first.sync.seedFromViewport(0);
    await container.pump();
    fixture.events.add(
      api.CanvasObjectPlaced(
        channelId: 'c1',
        object: api.CanvasObject.fromJson(canvasObjectJson('a')),
      ),
    );
    await container.pump();
    expect(first.document.knows('a'), isTrue);

    firstSub.close();
    await container.pump();
    expect(first.mounted, isFalse);

    final secondSub = container.listen(canvasEngineProvider('c1'), (_, _) {});
    addTearDown(secondSub.close);
    final second = container.read(canvasEngineProvider('c1').notifier);
    second.sync.seedFromViewport(0);

    expect(identical(first, second), isFalse);
    expect(second.document.knows('a'), isFalse);
  });

  test('two channels open at once do not share a document', () async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    final subA = container.listen(canvasEngineProvider('c1'), (_, _) {});
    final subB = container.listen(canvasEngineProvider('c2'), (_, _) {});
    addTearDown(subA.close);
    addTearDown(subB.close);
    final engineA = container.read(canvasEngineProvider('c1').notifier);
    engineA.sync.seedFromViewport(0);
    final engineB = container.read(canvasEngineProvider('c2').notifier);
    engineB.sync.seedFromViewport(0);
    await container.pump();

    fixture.events.add(
      api.CanvasObjectPlaced(
        channelId: 'c1',
        object: api.CanvasObject.fromJson(canvasObjectJson('a')),
      ),
    );
    await container.pump();

    expect(engineA.document.knows('a'), isTrue);
    expect(engineB.document.knows('a'), isFalse);
  });
}
