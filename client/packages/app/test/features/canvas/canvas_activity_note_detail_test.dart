// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note's activity detail must stay well-formed UTF-16 and one line.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';

api.CanvasObject _note(String text) => api.CanvasObject(
  id: 'n1',
  kind: 'note',
  zIndex: 1,
  x: 0,
  y: 0,
  w: 1,
  h: 1,
  props: {'text': text},
  authorId: 'alice',
  seq: 1,
  createdAt: 0,
);

bool _wellFormed(String s) {
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 >= units.length ||
          units[i + 1] < 0xDC00 ||
          units[i + 1] > 0xDFFF) {
        return false;
      }
      i++;
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      return false;
    }
  }
  return true;
}

void main() {
  test('a note with an emoji straddling the 80th unit stays well-formed', () {
    final log = CanvasActivityLog(isBlocked: (_) => false);
    addTearDown(log.dispose);
    final text = '${'a' * 79}\u{1F600} tail';

    log.recordPlacedLive(_note(text));

    final detail = log.entries.single.detail!;
    expect(_wellFormed(detail), isTrue, reason: 'lone surrogate in "$detail"');
    expect(
      _wellFormed(describeCanvasActivityEntry(log.entries.single)),
      isTrue,
    );
  });

  test('a multi-line note collapses to one line in the activity row', () {
    final log = CanvasActivityLog(isBlocked: (_) => false);
    addTearDown(log.dispose);

    log.recordPlacedLive(_note('first\nsecond\n\nthird'));

    expect(log.entries.single.detail, isNot(contains('\n')));
  });
}
