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
import 'package:slimm_api/api.dart' show AppLog, LogTag, versionedWebAssetUrl;
import 'package:web/web.dart' as web;

import 'capture_chain_guard.dart';
import 'web_capture_chain_processor.dart';
import 'web_capture_chain_settings.dart';

/// Both files sit next to index.html; tool/fetch_web_assets.sh copies them from the fork.
const _workletFile = 'capture_chain_worklet.js';
const _wasmFile = 'capture_chain.wasm';
const _processorName = 'slimm-capture-chain';

/// A worklet that has not answered by then is suspended; the poll skips a beat.
const _readTimeout = Duration(milliseconds: 300);

/// A context that has not resumed by then is not going to, as on Safari outside a gesture.
const _resumeTimeout = Duration(seconds: 2);

final _failures = StreamController<void>.broadcast();

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
      chainFailures: _failures.stream,
    );

Future<rtc.MediaStreamTrack> attachWebCaptureChain(
  rtc.MediaStreamTrack track,
) async {
  final chain = await _Chain.shared();
  if (chain == null) return track;
  return attachOrRaw(
    attach: () => chain._attach(track),
    raw: track,
    timeout: _resumeTimeout,
    onFailed: chain._failedAttach,
  );
}

Future<void> detachWebCaptureChain(rtc.MediaStreamTrack processed) async =>
    _Chain._loaded?._detach(processed);

class _Chain {
  _Chain._(this._context, this._node) {
    _node.port.onmessage = _onMessage.toJS;
    _node.onprocessorerror = _onProcessorError.toJS;
    _context.onstatechange = (web.Event _) {
      _resumeIfNeeded();
    }.toJS;
    web.document.addEventListener('visibilitychange', _onWake);
    web.document.addEventListener('pointerdown', _onWake);
  }

  static _Chain? _loaded;
  static Future<_Chain?>? _loading;

  static final _retry = ChainRetry();

  static bool get failed => _loaded == null && _retry.failed;

  /// Loaded once, on the first microphone that needs it; a failure is tried again after a pause.
  static Future<_Chain?> shared() {
    if (_retry.due(DateTime.now())) {
      _retry.clear();
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
    web.AudioContext? context;
    try {
      context = web.AudioContext(
        web.AudioContextOptions(
          sampleRate: 48000,
          latencyHint: 'interactive'.toJS,
        ),
      );
      await context.audioWorklet
          .addModule(versionedWebAssetUrl(_workletFile))
          .toDart;
      final response =
          await web.window.fetch(versionedWebAssetUrl(_wasmFile).toJS).toDart;
      if (!response.ok) throw StateError('$_wasmFile: HTTP ${response.status}');
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
      _retry.clear();
      return _loaded = chain;
    } on Object catch (error, stack) {
      _retry.fail(DateTime.now());
      unawaited(_closeQuietly(context));
      AppLog.swallowed(
        LogTag.voice,
        'The browser capture chain did not load; the mic is sent unprocessed',
        error,
        stack,
      );
      return null;
    }
  }

  static Future<void> _closeQuietly(web.AudioContext? context) async {
    try {
      await context?.close().toDart;
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'Closing the capture context', error, stack);
    }
  }

  void _onProcessorError(web.Event _) {
    AppLog.swallowed(
      LogTag.voice,
      'The browser capture chain stopped inside its worklet; the mic is sent unprocessed',
      StateError('processorerror'),
      StackTrace.current,
    );
    _giveUp();
    _failures.add(null);
  }

  void _failedAttach(Object error, StackTrace stack) {
    AppLog.swallowed(
      LogTag.voice,
      'The browser capture chain could not attach; the mic is sent unprocessed',
      error,
      stack,
    );
    _giveUp();
  }

  /// Tears the chain down and pauses before the next microphone tries a new one.
  void _giveUp() {
    _retry.fail(DateTime.now());
    if (identical(_loaded, this)) {
      _loaded = null;
      _loading = Future.value();
    }
    _source?.disconnect();
    _destination?.disconnect();
    _node.disconnect();
    _source = null;
    _destination = null;
    _output = null;
    web.document.removeEventListener('visibilitychange', _onWake);
    web.document.removeEventListener('pointerdown', _onWake);
    unawaited(_closeQuietly(_context));
  }

  late final JSFunction _onWake = ((web.Event _) => _resumeIfNeeded()).toJS;

  void _resumeIfNeeded() {
    if (!contextNeedsResume(_context.state, inUse: _source != null)) return;
    _context.resume().toDart.then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) => AppLog.swallowed(
            LogTag.voice,
            'The capture context would not resume',
            error,
            stack,
          ),
        );
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
    _output = null;
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
