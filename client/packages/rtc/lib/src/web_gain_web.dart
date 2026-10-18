// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-track playback gain in a browser, through Web Audio.
///
/// livekit_client plays each remote audio track through an `HTMLAudioElement`
/// it names `livekit_audio_<cid>` and does not expose. Its stream is routed
/// through a `GainNode` and the element is muted, so the context is the only
/// thing heard. Chrome only feeds a remote stream to Web Audio while an
/// element is playing it, which the muted element still is.
library;

import 'dart:js_interop';

import 'gain_graph_registry.dart';

const _elementPrefix = 'livekit_audio_';

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external _AudioElement? getElementById(String id);
}

extension type _AudioElement._(JSObject _) implements JSObject {
  external JSObject? get srcObject;
  external set muted(bool value);
}

@JS('AudioContext')
extension type _AudioContext._(JSObject _) implements JSObject {
  external _AudioContext();
  external JSObject get destination;
  external _Node createMediaStreamSource(JSObject stream);
  external _GainNode createGain();
  external JSPromise<JSAny?> resume();
}

extension type _Node._(JSObject _) implements JSObject {
  external void connect(JSObject destination);
  external void disconnect();
}

extension type _GainNode._(JSObject _) implements _Node {
  external _GainParam get gain;
}

extension type _GainParam._(JSObject _) implements JSObject {
  external set value(double value);
}

class _Graph {
  _Graph(this.element, this.stream, this.source, this.gain);

  final _AudioElement element;
  final JSObject stream;
  final _Node source;
  final _GainNode gain;
}

_AudioContext? _context;

_AudioContext get _ctx => _context ??= _AudioContext();

_Graph? _attach(String id) {
  final element = _document.getElementById(id);
  final stream = element?.srcObject;
  if (element == null || stream == null) return null;
  final context = _ctx;
  final source = context.createMediaStreamSource(stream);
  final gain = context.createGain();
  source.connect(gain);
  gain.connect(context.destination);
  element.muted = true;
  return _Graph(element, stream, source, gain);
}

bool _isCurrent(String id, _Graph graph) {
  final now = _document.getElementById(id);
  return now != null &&
      now.strictEquals(graph.element).toDart &&
      now.srcObject?.strictEquals(graph.stream).toDart == true;
}

void _release(_Graph graph) {
  graph.source.disconnect();
  graph.gain.disconnect();
  graph.element.muted = false;
}

final _registry = GainGraphRegistry<_Graph>(
  attach: _attach,
  isCurrent: _isCurrent,
  release: _release,
  setGain: (graph, gain) {
    graph.gain.gain.value = gain;
    _ctx.resume();
  },
);

Object? applyWebGain(String trackCid, double gain) =>
    _registry.apply('$_elementPrefix$trackCid', gain);

@JS('MutationObserver')
extension type _Observer._(JSObject _) implements JSObject {
  external _Observer(JSFunction callback);
  external void observe(JSObject target, JSObject options);
  external void disconnect();
}

@JS('document.body')
external JSObject get _body;

@JS('document.querySelectorAll')
external _NodeList _querySelectorAll(String selector);

extension type _NodeList._(JSObject _) implements JSObject {
  external int get length;
  external _DomNode? item(int index);
}

extension type _DomNode._(JSObject _) implements JSObject {
  external int get nodeType;
  external String? get id;
  external String get tagName;
  external _NodeList querySelectorAll(String selector);
}

extension type _MutationRecord._(JSObject _) implements JSObject {
  external _NodeList get addedNodes;
  external _NodeList get removedNodes;
}

const _elementNode = 1;
const _audioSelector = 'audio[id^="$_elementPrefix"]';

void _forEachAudioId(_NodeList nodes, void Function(String id) visit) {
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes.item(i)!;
    if (node.nodeType != _elementNode) continue;
    final id = node.id;
    if (node.tagName == 'AUDIO' && id!.startsWith(_elementPrefix)) visit(id);
    final inside = node.querySelectorAll(_audioSelector);
    for (var j = 0; j < inside.length; j++) {
      visit(inside.item(j)!.id!);
    }
  }
}

/// Reports each new `livekit_audio_*` element once, in the microtask after the
/// browser inserts it, which is before the stream behind it has produced sound.
///
/// Reads only the nodes each mutation added or removed: Flutter's semantics
/// tree mutates the body every frame, so a document rescan would run at that rate.
void Function() watchWebAudioArrivals(void Function(String trackId) onArrive) {
  final seen = <String>{};
  void arrive(String id) {
    if (seen.add(id)) onArrive(id.substring(_elementPrefix.length));
  }

  final existing = _querySelectorAll(_audioSelector);
  for (var i = 0; i < existing.length; i++) {
    arrive(existing.item(i)!.id!);
  }

  void onMutations(JSArray<_MutationRecord> records) {
    for (final record in records.toDart) {
      _forEachAudioId(record.removedNodes, seen.remove);
      _forEachAudioId(record.addedNodes, arrive);
    }
  }

  final observer = _Observer(
    ((JSArray<_MutationRecord> records, JSAny? _) => onMutations(records)).toJS,
  );
  observer.observe(
      _body, {'childList': true, 'subtree': true}.jsify()! as JSObject);
  return () => observer.disconnect();
}
