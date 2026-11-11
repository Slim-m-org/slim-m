// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stage fit (decision 0114): every tile inside the box and clear of the
/// others, shares exactly at their aspect, cameras cropped at most 15%, and
/// the owner's approved scenarios landing on the shapes they were shown with.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/layout/stage_fit.dart';

const _gap = 12.0;
const _w1280 = Size(992, 632);
const _w1920 = Size(1632, 912);
const _phone = Size(358, 560);

List<StageItem> _shares(int n, [double aspect = 16 / 9]) => [
  for (var i = 0; i < n; i++) StageItem('s$i', StageKind.share, aspect),
];

List<StageItem> _cams(int n, [double aspect = 16 / 9]) => [
  for (var i = 0; i < n; i++) StageItem('c$i', StageKind.camera, aspect),
];

StageFit _fit(Size box, List<StageItem> content, [int people = 0]) =>
    fitStage(box: box, gap: _gap, content: content, people: people);

void _expectInside(StageFit fit, Size box) {
  final bounds = (Offset.zero & box).inflate(0.01);
  for (final r in [...fit.items.values, ...fit.people]) {
    expect(bounds.contains(r.topLeft), isTrue, reason: '$r in $box');
    expect(bounds.contains(r.bottomRight), isTrue, reason: '$r in $box');
  }
}

void _expectClear(StageFit fit) {
  final all = [...fit.items.values, ...fit.people];
  for (var i = 0; i < all.length; i++) {
    for (var j = i + 1; j < all.length; j++) {
      final inter = all[i].intersect(all[j]);
      expect(
        inter.width > 0.01 && inter.height > 0.01,
        isFalse,
        reason: '${all[i]} overlaps ${all[j]}',
      );
    }
  }
}

void main() {
  final scenarios = <String, (Size, List<StageItem>, int)>{
    'six shares 1280': (_w1280, _shares(6), 0),
    'six shares 1920': (_w1920, _shares(6), 0),
    'mixed 1280': (_w1280, [..._shares(2), ..._cams(4)], 6),
    'one camera and nine people': (_w1920, _cams(1), 9),
    'phone shares and cameras': (_phone, [..._shares(2), ..._cams(4)], 0),
    'ten cameras': (_w1280, _cams(10), 0),
    'only people': (_w1920, <StageItem>[], 7),
    'a crowd of audio': (_phone, _shares(1), 30),
    'portrait phone share': (
      _phone,
      [const StageItem('p', StageKind.share, 9 / 16), ..._cams(3, 4 / 3)],
      3,
    ),
  };

  for (final e in scenarios.entries) {
    final (box, content, people) = e.value;
    group(e.key, () {
      test('every rect is inside the box and none overlap', () {
        final fit = _fit(box, content, people);
        _expectInside(fit, box);
        _expectClear(fit);
        expect(fit.items.length, content.length);
      });

      test('shares keep their aspect and cameras crop at most 15%', () {
        final fit = _fit(box, content, people);
        for (final item in content) {
          final r = fit.items[item.id]!;
          if (item.kind == StageKind.share) {
            expect(r.width / r.height, closeTo(item.aspect, 0.005));
          } else {
            expect(fit.crop[item.id] ?? 0, lessThanOrEqualTo(0.1501));
            final shown = r.width / r.height;
            final cut = shown >= item.aspect
                ? 1 - item.aspect / shown
                : 1 - shown / item.aspect;
            expect(cut, lessThanOrEqualTo(0.1501));
          }
        }
      });

      test('the same input gives the same layout', () {
        final a = _fit(box, content, people);
        final b = _fit(box, content, people);
        expect(a.items, b.items);
        expect(a.people, b.people);
        expect(a.shape, b.shape);
      });
    });
  }

  test('the fit covers at least what the best plain grid does', () {
    for (final box in [_w1280, _w1920, _phone]) {
      for (final content in [
        _shares(6),
        [..._shares(2), ..._cams(4)],
        _cams(10),
        _shares(3),
      ]) {
        expect(
          _fit(box, content).fill,
          greaterThanOrEqualTo(plainGridFill(box, _gap, content) - 1e-9),
          reason: '${content.length} items in $box',
        );
      }
    }
  });

  test('six shares in the 1280 stage pick a pinned item with a row', () {
    final fit = _fit(_w1280, _shares(6));
    expect(fit.shape, StageShape.pinnedRow);
    expect(fit.fill, greaterThan(0.9));
  });

  test('six shares in the 1920 stage pick the bento', () {
    final fit = _fit(_w1920, _shares(6));
    expect(fit.shape, StageShape.bento);
    expect(fit.fill, greaterThan(0.94));
  });

  test('two shares, four cameras and six people fill about 90%', () {
    final fit = _fit(_w1280, [..._shares(2), ..._cams(4)], 6);
    expect(fit.fill, greaterThan(0.85));
    expect(fit.people, hasLength(6));
    expect(fit.peopleCollapsed, isFalse);
  });

  test('ten people with one camera: the camera full width, a strip below', () {
    final fit = _fit(_w1920, _cams(1), 9);
    final cam = fit.items['c0']!;
    expect(cam.width, greaterThan(_w1920.width * 0.98));
    expect(fit.people, hasLength(9));
    expect(fit.people.every((r) => r.top > cam.bottom), isTrue);
    expect({for (final r in fit.people) r.top}, hasLength(1), reason: 'a row');
  });

  test('on a phone the shares stack and the cameras sit two by two', () {
    final fit = _fit(_phone, [..._shares(2), ..._cams(4)]);
    final cams = [for (var i = 0; i < 4; i++) fit.items['c$i']!];
    expect({for (final r in cams) r.top.round()}, hasLength(2));
    expect({for (final r in cams) r.left.round()}, hasLength(2));
    expect(fit.items['s0']!.width, greaterThan(_phone.width * 0.8));
  });

  test('the pinned item is never smaller than another', () {
    for (final box in [_w1280, _w1920, _phone]) {
      final fit = _fit(box, [..._shares(3), ..._cams(3)]);
      final pinned = fit.items['s0']!;
      for (final r in fit.items.values) {
        expect(
          r.width * r.height,
          lessThanOrEqualTo(pinned.width * pinned.height * 1.001),
        );
      }
    }
  });

  test('too many people for tiles collapse to chips with a +N', () {
    final fit = _fit(_phone, _shares(1), 30);
    expect(fit.peopleCollapsed, isTrue);
    expect(fit.peopleOverflow, greaterThan(0));
    expect(fit.people.last.width, greaterThan(0));
    expect(fit.people.length - 1 + fit.peopleOverflow, 30);
  });

  test('with no content the people use the whole box, uncapped', () {
    final fit = _fit(_w1920, <StageItem>[], 2);
    expect(fit.shape, StageShape.peopleGrid);
    expect(fit.people.first.width, greaterThan(720));
  });

  test('an empty call lays out nothing', () {
    final fit = _fit(_w1280, <StageItem>[]);
    expect(fit.items, isEmpty);
    expect(fit.people, isEmpty);
    expect(fit.shape, StageShape.none);
  });
}
