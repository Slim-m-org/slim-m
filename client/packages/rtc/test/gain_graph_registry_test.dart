// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web gain path's attach and release rules, without a browser.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/gain_graph_registry.dart';

class _Graph {
  _Graph(this.id);

  final String id;
  double gain = 1.0;
  bool released = false;
}

class _Fixture {
  final present = <String>{'a'};
  final stale = <_Graph>{};
  final built = <_Graph>[];

  late final registry = GainGraphRegistry<_Graph>(
    attach: (id) {
      if (!present.contains(id)) return null;
      return _Graph(id)..also(built.add);
    },
    isCurrent: (id, graph) => !stale.contains(graph),
    release: (graph) => graph.released = true,
    setGain: (graph, gain) => graph.gain = gain,
  );
}

extension on _Graph {
  void also(void Function(_Graph) f) => f(this);
}

void main() {
  test('a changed gain builds one graph and reuses it', () {
    final f = _Fixture();

    expect(f.registry.apply('a', 1.5), isNull);
    expect(f.registry.apply('a', 0.25), isNull);

    expect(f.built, hasLength(1));
    expect(f.built.single.gain, 0.25);
  });

  test('gain above 1.0 is passed through untouched', () {
    final f = _Fixture();
    f.registry.apply('a', 2.0);
    expect(f.built.single.gain, 2.0);
  });

  test('unity builds nothing and releases an existing graph', () {
    final f = _Fixture();

    expect(f.registry.apply('a', 1.0), isNull);
    expect(f.built, isEmpty);

    f.registry.apply('a', 1.4);
    f.registry.apply('a', 1.0);
    expect(f.built.single.released, isTrue);
  });

  test('a missing element is a failure, not a silent success', () {
    final f = _Fixture();

    expect(f.registry.apply('gone', 1.4), isA<StateError>());
    f.present.add('gone');
    expect(f.registry.apply('gone', 1.4), isNull);
  });

  test('a graph for a replaced stream is released and rebuilt', () {
    final f = _Fixture();
    f.registry.apply('a', 1.4);
    f.stale.add(f.built.single);

    f.registry.apply('a', 1.4);

    expect(f.built, hasLength(2));
    expect(f.built.first.released, isTrue);
    expect(f.built.last.released, isFalse);
  });
}
