// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a viewer's feed does with a stamp: fetch its picture, start its clock
/// once the picture is in, and never fetch anything for a blocked author or
/// one outside my call.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';

import 'stamp_frames.dart';

api.CanvasScreenAnnotation _consent(String sharer, {bool allowed = true}) =>
    api.CanvasScreenAnnotation(
      channelId: 'c',
      userId: sharer,
      targetUserId: sharer,
      kind: 'consent',
      points: const [],
      ended: false,
      allowed: allowed,
      stamps: true,
    );

void main() {
  var now = DateTime(2026, 11, 16, 12);
  late ScreenAnnotationFeed feed;
  late List<StampContent> loads;
  late Map<StampContent, Completer<void>> pending;
  final blocked = <String>{};

  setUp(() {
    now = DateTime(2026, 11, 16, 12);
    loads = [];
    pending = {};
    blocked.clear();
    feed = ScreenAnnotationFeed(
      selfId: () => 'me',
      callChannelId: () => 'c',
      callMembers: () => const ['me', 'sharer', 'viewer'],
      clock: () => now,
      isBlocked: blocked.contains,
      loadStamp: (content) {
        loads.add(content);
        return (pending[content] = Completer<void>()).future;
      },
    );
  });

  tearDown(() => feed.dispose());

  test(
    'a stamp shows once its picture is in, and its clock starts then',
    () async {
      feed.handle(_consent('sharer'));
      feed.handle(stampFrame(attachment: 'abc'));
      expect(loads, [const PictureStamp('abc')]);
      final mark = feed.marksFor('sharer').single;
      expect(mark.alphaAt(now), 0);

      now = now.add(const Duration(seconds: 1));
      pending.values.single.complete();
      await pumpEventQueue();
      expect(mark.readyAt, now);
      expect(mark.alphaAt(now), 1);
    },
  );

  test('a blocked author\'s stamp is dropped before anything is fetched', () {
    blocked.add('viewer');
    feed.handle(_consent('sharer'));
    feed.handle(stampFrame(attachment: 'abc'));
    expect(loads, isEmpty);
    expect(feed.marksFor('sharer'), isEmpty);
  });

  test('a stamp from someone outside my call fetches nothing', () {
    feed.handle(_consent('sharer'));
    feed.handle(stampFrame(user: 'outsider', attachment: 'abc'));
    expect(loads, isEmpty);
    expect(feed.marksFor('sharer'), isEmpty);
  });

  test('a stamp over a sharer who allows nothing fetches nothing', () {
    feed.handle(stampFrame(attachment: 'abc'));
    expect(loads, isEmpty);
  });

  test('a picture that will not load is never shown', () async {
    feed.handle(_consent('sharer'));
    feed.handle(stampFrame(attachment: 'abc'));
    pending.values.single.completeError(StateError('404'));
    await pumpEventQueue();
    expect(feed.marksFor('sharer').single.readyAt, isNull);
  });

  test(
    'withdrawn consent takes stamps off at once, even one still loading',
    () async {
      feed.handle(_consent('sharer'));
      feed.handle(stampFrame(attachment: 'abc'));
      feed.handle(_consent('sharer', allowed: false));
      expect(feed.marksFor('sharer'), isEmpty);
      pending.values.single.complete();
      await pumpEventQueue();
      expect(feed.marksFor('sharer'), isEmpty);
    },
  );

  test(
    'my own stamp shows through the same load, then a refusal removes it',
    () async {
      feed.handle(_consent('sharer'));
      feed.applyLocal(stampFrame(user: 'me'));
      pending.values.single.complete();
      await pumpEventQueue();
      expect(feed.marksFor('sharer').single.readyAt, isNotNull);

      feed.remove('sharer', 's1');
      expect(feed.marksFor('sharer'), isEmpty);
    },
  );

  test('the relay\'s echo of my own stamp is not shown twice', () {
    feed.handle(_consent('sharer'));
    feed.applyLocal(stampFrame(user: 'me'));
    feed.handle(stampFrame(user: 'me'));
    expect(feed.marksFor('sharer'), hasLength(1));
    expect(loads, hasLength(1));
  });

  test('a stamp aimed at my own screen is kept for my preview', () {
    feed.handle(stampFrame(target: 'me'));
    expect(feed.marksFor('me'), hasLength(1));
  });

  test('the sharer\'s consent says if their client can show stamps', () {
    feed.handle(_consent('sharer'));
    expect(feed.consentFor('sharer')!.stamps, isTrue);
  });
}
