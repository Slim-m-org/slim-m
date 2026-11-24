// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An edge's props, and the hull the server and every client compute from the same vectors.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Map<String, Object?> end(String id, [String side = 'right']) => {
      'object_id': id,
      'side': side,
    };

void main() {
  test('a well formed edge parses and writes back the same props', () {
    final props = <String, Object?>{
      'from': end('a'),
      'to': {'x': 10.0, 'y': -4.5},
      'arrow': 'both',
      'color': 'amber',
      'label': 'depends on',
    };
    final spec = CanvasEdgeSpec.fromProps(props)!;
    expect(spec.arrow, EdgeArrow.both);
    expect(spec.from, const AttachedEnd('a', side: EdgeSide.right));
    expect(spec.to, const FreeEnd(Offset(10, -4.5)));
    expect(spec.attachedIds, ['a']);
    expect(CanvasEdgeSpec.fromProps(spec.toProps()), spec);
  });

  test('an auto side and the default arrow are not written to the props', () {
    const spec = CanvasEdgeSpec(
      from: AttachedEnd('a'),
      to: AttachedEnd('b'),
    );
    expect((spec.toProps()['from']! as Map).containsKey('side'), isFalse);
    expect(spec.toProps()['arrow'], 'end');
  });

  test('an edge needs one attached end and never joins an object to itself',
      () {
    const free = {'x': 1.0, 'y': 2.0};
    expect(CanvasEdgeSpec.fromProps({'from': free, 'to': free}), isNull);
    expect(
        CanvasEdgeSpec.fromProps({'from': end('a'), 'to': end('a')}), isNull);
    expect(CanvasEdgeSpec.fromProps({'from': end('a')}), isNull);
    expect(CanvasEdgeSpec.fromProps({'from': end('a'), 'to': free}), isNotNull);
  });

  test('the hull matches every shared vector', () {
    final vectors = jsonDecode(
      File('../../../schema/test-vectors/canvas_edge_hull.json')
          .readAsStringSync(),
    ) as List<Object?>;
    expect(vectors, isNotEmpty);
    for (final entry in vectors) {
      final vector = entry! as Map<String, Object?>;
      final parts = [
        for (final raw in vector['ends']! as List<Object?>)
          if (raw! as Map<String, Object?> case final e)
            e.containsKey('box')
                ? _box((e['box']! as List<Object?>).cast<num>())
                : _point((e['point']! as List<Object?>).cast<num>()),
      ];
      final h = edgeHull(parts);
      final want = (vector['hull']! as List<Object?>).cast<num>();
      expect([h.x, h.y, h.w, h.h], want.map((n) => n.toDouble()).toList(),
          reason: '${vector['name']}');
    }
  });
}

Rect _box(List<num> b) => Rect.fromLTWH(
    b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble());

Rect _point(List<num> p) =>
    Rect.fromLTWH(p[0].toDouble(), p[1].toDouble(), 0, 0);
