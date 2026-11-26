// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Objects picked together by a drag box or a modifier click.
///
/// One picked object is the ordinary single selection, with its handles and bars; two or more live here
/// and leave [CanvasDocument.selectedObjectId] empty, so nothing that acts on one object offers itself.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'canvas_document.dart';

class CanvasMultiSelection {
  CanvasMultiSelection(this._single) {
    _single.addListener(_onSingleChanged);
  }

  final ValueNotifier<String?> _single;

  /// The objects picked together, two or more or none, replaced as a whole.
  final ValueNotifier<Set<String>> ids = ValueNotifier(const {});

  /// The world rectangle a drag box is drawing right now, or null.
  final ValueNotifier<Rect?> marquee = ValueNotifier(null);

  bool contains(String id) => ids.value.contains(id) || _single.value == id;

  /// Every picked object, whether picked singly or together.
  Set<String> get all =>
      ids.value.isNotEmpty ? ids.value : {if (_single.value case final id?) id};

  /// Makes [picked] the whole selection: none clears, one is the single selection, more are kept here.
  void select(Iterable<String> picked) {
    final next = picked.toSet();
    switch (next.length) {
      case 0:
        _single.value = null;
        ids.value = const {};
      case 1:
        ids.value = const {};
        _single.value = next.single;
      default:
        _single.value = null;
        ids.value = next;
    }
  }

  /// Adds [id] when it is not picked, removes it when it is.
  void toggle(String id) {
    final next = {...all};
    next.remove(id) || next.add(id);
    select(next);
  }

  void add(Iterable<String> more) => select({...all, ...more});

  void clear() => select(const {});

  /// Drops [id] from a group pick, as an object that died or was deleted.
  void release(String id) {
    if (ids.value.contains(id)) select(ids.value.difference({id}));
  }

  void _onSingleChanged() {
    if (_single.value != null && ids.value.isNotEmpty) ids.value = const {};
  }

  void dispose() {
    _single.removeListener(_onSingleChanged);
    ids.dispose();
    marquee.dispose();
  }
}

/// The live boxes and shapes whose box meets [world], in paint order, that [accepts] allows.
/// Ink is left out: it can be erased or reordered but never dragged, so a group could not move as one.
List<String> objectIdsInRect(
  CanvasDocument document,
  Rect world, {
  bool Function(String id)? accepts,
}) =>
    [
      for (final slot in document.orderedSlotsIn(world))
        if (document.strokeAt(slot) case final stroke
            when stroke.kind != CanvasObjectKind.stroke &&
                Rect.fromLTWH(stroke.x, stroke.y, stroke.w, stroke.h)
                    .overlaps(world) &&
                (accepts?.call(stroke.id) ?? true))
          stroke.id,
    ];
