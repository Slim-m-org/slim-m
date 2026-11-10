// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a viewer's feed keeps: marks only over a screen whose sharer allowed
/// drawing, and no board that has nothing left to show.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_consent.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';

api.CanvasScreenAnnotation _consent(String sharer, {bool allowed = true}) =>
    api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: sharer,
      targetUserId: sharer,
      kind: 'consent',
      points: const [],
      ended: false,
      allowed: allowed,
    );

api.CanvasScreenAnnotation _stroke(
  String target, {
  String id = 'm1',
  bool ended = true,
}) => api.CanvasScreenAnnotation(
  channelId: 'call',
  userId: 'viewer',
  targetUserId: target,
  kind: 'stroke',
  annotationId: id,
  points: const [0.1, 0.1, 0.5, 0.5],
  color: 'blue',
  ended: ended,
  allowed: false,
);

void main() {
  var now = DateTime(2026, 11, 10, 12);
  late ScreenAnnotationFeed feed;
  late int notified;

  setUp(() {
    now = DateTime(2026, 11, 10, 12);
    feed = ScreenAnnotationFeed(selfId: () => 'me', clock: () => now);
    notified = 0;
    feed.addListener(() => notified++);
  });

  tearDown(() => feed.dispose());

  test('a mark over a sharer who has not allowed drawing is dropped', () {
    feed.handle(_stroke('stranger'));
    expect(feed.marksFor('stranger'), isEmpty);
    expect(feed.boardCount, 0);
    expect(notified, 0);
  });

  test('marks over random target ids never pile up boards', () {
    for (var i = 0; i < 50; i++) {
      feed.handle(_stroke('target-$i', id: 'm$i'));
    }
    expect(feed.boardCount, 0);
  });

  test('a mark over a sharer who allowed drawing is kept', () {
    feed.handle(_consent('sharer'));
    feed.handle(_stroke('sharer'));
    expect(feed.marksFor('sharer'), hasLength(1));
    expect(feed.boardCount, 1);
  });

  test('a mark over my own screen is kept for my preview of it', () {
    feed.handle(_stroke('me'));
    expect(feed.marksFor('me'), hasLength(1));
  });

  test('a mark after the sharer withdrew consent is dropped', () {
    feed.handle(_consent('sharer'));
    feed.handle(_consent('sharer', allowed: false));
    feed.handle(_stroke('sharer'));
    expect(feed.marksFor('sharer'), isEmpty);
    expect(feed.boardCount, 0);
  });

  test('a mark after the consent lapsed is dropped', () {
    feed.handle(_consent('sharer'));
    now = now.add(consentLifetime + const Duration(seconds: 1));
    feed.handle(_stroke('sharer'));
    expect(feed.marksFor('sharer'), isEmpty);
  });

  test('the rest of a mark in progress lands after consent is withdrawn', () {
    feed.handle(_consent('sharer'));
    feed.handle(_stroke('sharer', ended: false));
    feed.handle(_consent('sharer', allowed: false));
    feed.handle(_stroke('sharer', ended: true));
    expect(feed.marksFor('sharer').single.finishedAt, isNotNull);
  });

  test('a board with nothing left is dropped when the next frame folds', () {
    feed.handle(_consent('sharer'));
    feed.handle(_stroke('sharer'));
    expect(feed.boardCount, 1);

    now = now.add(annotationHold + annotationFade + const Duration(seconds: 1));
    feed.handle(_consent('sharer'));
    expect(feed.boardCount, 0);
  });

  test('a board that still has a live mark is kept', () {
    feed.handle(_consent('sharer'));
    feed.handle(_stroke('sharer'));
    now = now.add(const Duration(seconds: 1));
    feed.handle(_consent('sharer'));
    expect(feed.boardCount, 1);
  });

  test('a viewer\'s own mark is shown at once while consent holds', () {
    feed.handle(_consent('sharer'));
    feed.applyLocal(_stroke('sharer'));
    expect(feed.marksFor('sharer'), hasLength(1));
  });
}
