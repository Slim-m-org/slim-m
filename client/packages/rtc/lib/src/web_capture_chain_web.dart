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

import 'web_capture_chain_processor.dart';
import 'web_capture_chain_settings.dart';

/// Both files sit next to index.html; tool/fetch_web_assets.sh copies them from the fork.
const _workletUrl = 'capture_chain_worklet.js';
const _wasmUrl = 'capture_chain.wasm';
const _processorName = 'slimm-capture-chain';

/// A worklet that has not answered by then is suspended; the poll skips a beat.
const _readTimeout = Duration(milliseconds: 300);

/// How long a failed load waits before the next microphone tries it again.
const _retryPause = Duration(seconds: 30);

bool get webCaptureChainAvailable =>
    web.window.isSecureContext &&
    globalContext.has('AudioWorkletNode') &&
    globalContext.has('WebAssembly');

final _settings = WebCaptureChainSettings();

/// What the poll reports once the chain failed to load: the mic is raw, so Strong reads as not running.
const _unavailableReading = {'voice': false, 'strongNoiseSuppression': false};

Future<Object?> invokeWebCaptureChain(String method, [Object? args]) async {
  switch (method) {
    case 'setInputGate':
      _settings.update(args);
      _Chain._loaded?._configure();
      return null;
    case 'getInputGate':
      return _Chain._loaded?._read() ??
          (_Chain.failed ? _unavailableReading : null);
  }
  throw UnsupportedError('$method has no web capture chain equivalent');
}

lk.TrackProcessor<lk.AudioProcessorOptions>? webCaptureProcessor() =>
    WebCaptureProcessor(
      name: _processorName,
      attach: attachWebCaptureChain,
      detach: detachWebCaptureChain,
    );

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

  static DateTime? _retryAfter;

  static bool get failed => _loaded == null && _retryAfter != null;

  /// Loaded once, on the first microphone that needs it; a failure is tried again after a pause.
  static Future<_Chain?> shared() {
    final retryAfter = _retryAfter;
    if (retryAfter != null && DateTime.now().isAfter(retryAfter)) {
      _retryAfter = null;
      _loading = null;
    }
    return _loading ??= _load();
  }

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
      _retryAfter = null;
      return _loaded = chain;
    } on Object catch (error, stack) {
      _retryAfter = DateTime.now().add(_retryPause);
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
