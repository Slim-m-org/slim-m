// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  const target = Rect.fromLTWH(100, 100, 50, 50);

  test('left edge snaps onto a target edge inside the threshold', () {
    final r = snapRect(
      const Rect.fromLTWH(153, 300, 20, 20),
      [target],
      threshold: 6,
    );
    expect(r.offset, const Offset(-3, 0));
  });

  test('outside the threshold nothing moves and no guide is drawn', () {
    final r = snapRect(
      const Rect.fromLTWH(160, 300, 20, 20),
      [target],
      threshold: 6,
    );
    expect(r.offset, Offset.zero);
    expect(r.guides, isEmpty);
  });

  test('centres align and each axis snaps independently', () {
    final r = snapRect(
      const Rect.fromLTWH(77, 77, 100, 100),
      [target],
      threshold: 6,
    );
    expect(r.offset, const Offset(-2, -2));
  });

  test('the closest line wins when several are in reach', () {
    final r = snapRect(
      const Rect.fromLTWH(152, 0, 10, 10),
      [target, const Rect.fromLTWH(155, 300, 10, 10)],
      threshold: 6,
    );
    expect(r.offset.dx, -2);
  });

  test('guide spans moving box and every matching target', () {
    final r = snapRect(
      const Rect.fromLTWH(100, 300, 20, 20),
      [target],
      threshold: 6,
    );
    expect(r.guides, [
      const SnapGuide(vertical: true, position: 100, start: 100, end: 320),
    ]);
  });

  test('a zero-size rect snaps a single point', () {
    final r =
        snapRect(const Rect.fromLTWH(148, 103, 0, 0), [target], threshold: 6);
    expect(r.offset, const Offset(2, -3));
  });

  test('no targets means no snap', () {
    expect(
      snapRect(const Rect.fromLTWH(1, 1, 5, 5), const [], threshold: 6),
      isA<SnapResult>().having((s) => s.offset, 'offset', Offset.zero),
    );
  });
}
