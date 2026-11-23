// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fork's capture chain as `capture_chain.wasm` in an AudioWorklet, between
/// the microphone and the track LiveKit publishes. See docs/voice-input-gate.md.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamTrackWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:web/web.dart' as web;

import 'web_capture_chain_settings.dart';

/// Both files sit next to index.html; tool/fetch_web_assets.sh copies them from the fork.
const _workletUrl = 'capture_chain_worklet.js';
const _wasmUrl = 'capture_chain.wasm';
const _processorName = 'slimm-capture-chain';

/// A worklet that has not answered by then is suspended; the poll skips a beat.
const _readTimeout = Duration(milliseconds: 300);

bool get webCaptureChainAvailable =>
    web.window.isSecureContext &&
    globalContext.has('AudioWorkletNode') &&
    globalContext.has('WebAssembly');

final _settings = WebCaptureChainSettings();

Future<Object?> invokeWebCaptureChain(String method, [Object? args]) async {
  switch (method) {
    case 'setInputGate':
      _settings.update(args);
      _Chain._loaded?._configure();
      return null;
    case 'getInputGate':
      return _Chain._loaded?._read();
  }
  throw UnsupportedError('$method has no web capture chain equivalent');
}

lk.TrackProcessor<lk.AudioProcessorOptions>? webCaptureProcessor() =>
    _WebCaptureProcessor();

Future<rtc.MediaStreamTrack> attachWebCaptureChain(
  rtc.MediaStreamTrack track,
) async =>
    await (await _Chain.shared())?._attach(track) ?? track;

Future<void> detachWebCaptureChain(rtc.MediaStreamTrack processed) async =>
    _Chain._loaded?._detach(processed);

class _Chain {
  _Chain._(this._context, this._node) {
    _node.port.onmessage = _onMessage.toJS;
  }

  static _Chain? _loaded;
  static Future<_Chain?>? _loading;

  /// Loaded once, on the first microphone that needs it; a failure is not retried.
  static Future<_Chain?> shared() => _loading ??= _load();

  final web.AudioContext _context;
  final web.AudioWorkletNode _node;
  web.MediaStreamAudioSourceNode? _source;
  web.MediaStreamAudioDestinationNode? _destination;
  rtc.MediaStreamTrack? _output;
  int _nextRead = 0;
  final _reads = <int, Completer<Map<Object?, Object?>?>>{};

  static Future<_Chain?> _load() async {
    try {
      final context = web.AudioContext(
        web.AudioContextOptions(
          sampleRate: 48000,
          latencyHint: 'interactive'.toJS,
        ),
      );
      await context.audioWorklet.addModule(_workletUrl).toDart;
      final response = await web.window.fetch(_wasmUrl.toJS).toDart;
      if (!response.ok) throw StateError('$_wasmUrl: HTTP ${response.status}');
      final wasm = await response.arrayBuffer().toDart;
      final options = JSObject()..['wasm'] = wasm;
      final node = web.AudioWorkletNode(
        context,
        _processorName,
        web.AudioWorkletNodeOptions(
          numberOfInputs: 1,
          numberOfOutputs: 1,
          channelCount: 1,
          channelCountMode: 'explicit',
          outputChannelCount: [1.toJS].toJS,
          processorOptions: options,
        ),
      );
      final chain = _Chain._(context, node).._configure();
      return _loaded = chain;
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'The browser capture chain did not load; the mic is sent unprocessed',
        error,
        stack,
      );
      return null;
    }
  }

  void _configure() => _node.port.postMessage(_settings.message.jsify());

  Future<Map<Object?, Object?>?> _read() {
    if (_source == null) return Future.value();
    final id = _nextRead++;
    final done = _reads[id] = Completer<Map<Object?, Object?>?>();
    _node.port.postMessage({'type': 'read', 'id': id}.jsify());
    return done.future.timeout(_readTimeout, onTimeout: () {
      _reads.remove(id);
      return null;
    });
  }

  void _onMessage(web.MessageEvent event) {
    final data = event.data.dartify();
    if (data is! Map || data['type'] != 'reading') return;
    final id = (data['id'] as num?)?.toInt();
    _reads.remove(id)?.complete(data);
  }

  Future<rtc.MediaStreamTrack> _attach(rtc.MediaStreamTrack track) async {
    final input = (track as MediaStreamTrackWeb).jsTrack;
    _source?.disconnect();
    _destination?.disconnect();
    _node.disconnect();
    final source = _source = _context.createMediaStreamSource(
      web.MediaStream([input].toJS),
    );
    final destination = _destination = _context.createMediaStreamDestination();
    source.connect(_node);
    _node.connect(destination);
    await _context.resume().toDart;
    final output = destination.stream.getAudioTracks().toDart.first;
    return _output = MediaStreamTrackWeb(output);
  }

  /// Leaves a newer attach alone; with nothing attached the context sleeps.
  Future<void> _detach(rtc.MediaStreamTrack processed) async {
    if (!identical(processed, _output)) return;
    _source?.disconnect();
    _node.disconnect();
    _source = null;
    _destination = null;
    _output = null;
    await _context.suspend().toDart;
  }
}

/// Runs a LiveKit microphone track through the chain before it is published.
class _WebCaptureProcessor
    implements lk.TrackProcessor<lk.AudioProcessorOptions> {
  rtc.MediaStreamTrack? _processed;
  lk.Room? _room;

  @override
  String get name => _processorName;

  @override
  rtc.MediaStreamTrack? get processedTrack => _processed;

  @override
  Future<void> init(lk.AudioProcessorOptions options) async {
    final processed = await attachWebCaptureChain(options.track);
    _processed = identical(processed, options.track) ? null : processed;
    await _sendProcessed();
  }

  @override
  Future<void> restart(lk.AudioProcessorOptions options) => init(options);

  @override
  Future<void> destroy() async {
    final processed = _processed;
    _processed = null;
    if (processed == null) return;
    await detachWebCaptureChain(processed);
    await processed.stop();
  }

  @override
  Future<void> onPublish(lk.Room room) async => _room = room;

  @override
  Future<void> onUnpublish() async => _room = null;

  /// `LocalTrack.restartTrack` hands the sender the raw capture before it sets
  /// the processor again, so a restarted track would go out unprocessed.
  Future<void> _sendProcessed() async {
    final processed = _processed;
    final room = _room;
    if (processed == null || room == null) return;
    for (final publication
        in room.localParticipant?.audioTrackPublications ?? const []) {
      final track = publication.track;
      if (track == null || !identical(track.processor, this)) continue;
      final sender = track.sender;
      if (sender != null && sender.track?.id != processed.id) {
        await sender.replaceTrack(processed);
      }
    }
  }
}
