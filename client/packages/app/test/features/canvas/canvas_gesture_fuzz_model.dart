// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the fake server holds after everything the pane sent and every live
/// frame the fuzz injected, so a run can tell the pane's picture of the board
/// from the real one.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'dart:ui';

import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_gesture_fuzz_rig.dart';

class FuzzServerModel {
  FuzzServerModel(this.rig) {
    for (final o in seededBoard()) {
      boxes[o['id'] as String] = _rect(o);
    }
  }

  final FuzzRig rig;
  final removed = <String>{};

  /// Ids of objects wholly outside the board that a local gesture touched.
  final touchedHidden = <String>{};
  final boxes = <String, Rect>{};

  /// Shrinks when the "bring in" pill moves one of them onto the board on purpose.
  final hiddenIds = <String>{'x1', 'x2'};

  /// False once an op the model cannot replay (restore, clear) was sent.
  var valid = true;

  var _opsSeen = 0;
  var _placedSeen = 0;

  static Rect _rect(Map<String, dynamic> o) => Rect.fromLTWH(
    (o['x'] as num).toDouble(),
    (o['y'] as num).toDouble(),
    (o['w'] as num).toDouble(),
    (o['h'] as num).toDouble(),
  );

  void livePlaced(Map<String, dynamic> json) =>
      boxes[json['id'] as String] = _rect(json);

  void liveRemoved(String id) => removed.add(id);

  void liveMoved(String id, Rect box) {
    boxes[id] = box;
    if (_insideBoard(box)) hiddenIds.remove(id);
  }

  static bool _insideBoard(Rect box) =>
      box.left >= canvasBoard.left - 0.5 &&
      box.top >= canvasBoard.top - 0.5 &&
      box.right <= canvasBoard.right + 0.5 &&
      box.bottom <= canvasBoard.bottom + 0.5;

  /// Folds in the requests the pane has sent since the last call.
  void absorbSent() {
    final ops = rig.fixture.postedOps;
    for (; _opsSeen < ops.length; _opsSeen++) {
      final op = ops[_opsSeen];
      switch (op['kind']) {
        case 'remove':
          final ids = (op['object_ids'] as List).cast<String>();
          removed.addAll(ids);
          touchedHidden.addAll(ids.where(hiddenIds.contains));
        case 'move':
          final id = op['object_id'] as String;
          boxes[id] = _rect(op);
          if (!hiddenIds.contains(id)) break;
          // A move onto the board is the "bring in" pill working as intended.
          if (_insideBoard(boxes[id]!)) {
            hiddenIds.remove(id);
          } else {
            touchedHidden.add(id);
          }
        case 'restore' || 'clear' || 'clear_scoped':
          valid = false;
      }
    }
    final placed = rig.fixture.posted;
    for (; _placedSeen < placed.length; _placedSeen++) {
      final body = placed[_placedSeen];
      final id = body['id'] as String;
      boxes[id] = _rect(body);
      if (!rig.knownIds.contains(id)) rig.knownIds.add(id);
    }
  }

  /// The ids the pane and the server disagree about, as readable lines.
  List<String> divergences() {
    if (!valid) return const [];
    final out = <String>[];
    for (final id in rig.knownIds) {
      final serverAlive = !removed.contains(id) && boxes.containsKey(id);
      final localAlive = rig.document.isAlive(id);
      if (serverAlive && !localAlive) {
        out.add('$id is alive on the server but gone from the pane');
      } else if (!serverAlive && localAlive) {
        out.add('$id was removed on the server but is still in the pane');
      } else if (serverAlive) {
        final local = rig.document.objectBounds(id);
        final server = boxes[id]!;
        if (local != null &&
            ((local.x - server.left).abs() > 0.5 ||
                (local.y - server.top).abs() > 0.5 ||
                (local.w - server.width).abs() > 0.5 ||
                (local.h - server.height).abs() > 0.5)) {
          out.add(
            '$id sits at (${local.x.round()},${local.y.round()} ${local.w.round()}x${local.h.round()}) '
            'in the pane but at (${server.left.round()},${server.top.round()} '
            '${server.width.round()}x${server.height.round()}) on the server',
          );
        }
      }
    }
    return out;
  }
}
