// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which audio elements currently have a gain graph spliced in, kept free of
/// any browser type so the attach/release rules run in a plain VM test.
library;

/// Gains this close to 1.0 need no graph; the element plays them untouched.
const double _unityTolerance = 0.0001;

class GainGraphRegistry<G> {
  GainGraphRegistry({
    required this.attach,
    required this.isCurrent,
    required this.release,
    required this.setGain,
  });

  /// Builds the graph for one element, or null when it has no stream yet.
  final G? Function(String id) attach;

  /// Whether [graph] still wraps what the element is playing now.
  final bool Function(String id, G graph) isCurrent;

  final void Function(G graph) release;
  final void Function(G graph, double gain) setGain;

  final Map<String, G> _graphs = {};

  /// Sets the gain on [id], returning why it could not or null on success.
  ///
  /// Unity releases the graph, which hands playback back to the element and
  /// so also its chosen output device; only a changed gain pays for a graph.
  Object? apply(String id, double gain) {
    var graph = _graphs[id];
    if (graph != null && !isCurrent(id, graph)) {
      release(graph);
      _graphs.remove(id);
      graph = null;
    }
    if ((gain - 1.0).abs() < _unityTolerance) {
      if (graph != null) {
        release(graph);
        _graphs.remove(id);
      }
      return null;
    }
    graph ??= attach(id);
    if (graph == null) return StateError('No playing audio element for $id');
    _graphs[id] = graph;
    setGain(graph, gain);
    return null;
  }
}
