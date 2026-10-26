// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the call's own playout out of shared desktop audio on Linux.
library;

import 'dart:async';

import 'pulse_audio.dart';

const _mixSink = 'slimm_share_mix';

/// The fork records the default sink's monitor, which holds everything played, including the call.
/// So for the length of a share the default sink becomes a private mix looped to the real
/// output, while this process's own streams play on the real output directly and never enter it.
class ShareAudioIsolation {
  ShareAudioIsolation({
    PulseAudio? pulse,
    this.repinEvery = const Duration(seconds: 1),
  }) : _pulse = pulse ?? PulseAudio();

  final PulseAudio _pulse;
  final Duration repinEvery;
  String? _realSink;
  String? _mixModule;
  String? _loopModule;
  Timer? _repin;

  bool get active => _mixModule != null;

  /// Returns false, changing nothing, when the sound server cannot be driven.
  Future<bool> begin() async {
    if (active) return true;
    if (!PulseAudio.supported) return false;
    await _dropLeftovers();
    final real = _strip(await _pulse.defaultNode(capture: false));
    if (real == null || real == _mixSink) return false;
    final mix = await _load('module-null-sink', [
      'sink_name=$_mixSink',
      'sink_properties=device.description=slim-m-share-mix',
    ]);
    if (mix == null) return false;
    final loop = await _load('module-loopback', [
      'source=$_mixSink.monitor',
      'sink=$real',
      'latency_msec=30',
    ]);
    if (loop == null) {
      await _pulse.pactl(['unload-module', mix]);
      return false;
    }
    _realSink = real;
    _mixModule = mix;
    _loopModule = loop;
    await _pulse.pactl(['set-default-sink', _mixSink]);
    await _divert();
    _repin = Timer.periodic(repinEvery, (_) => unawaited(_divert()));
    return true;
  }

  Future<void> end() async {
    _repin?.cancel();
    _repin = null;
    final real = _realSink;
    if (real == null) return;
    final current = await _pulse.pactl(['get-default-sink']);
    if (current?.trim() == _mixSink) {
      await _pulse.pactl(['set-default-sink', real]);
    }
    await _pulse.pactl(['unload-module', _loopModule!]);
    await _pulse.pactl(['unload-module', _mixModule!]);
    _realSink = _mixModule = _loopModule = null;
  }

  /// Own streams stay on the real output; everyone else's join the mix.
  Future<void> _divert() async {
    final real = _realSink;
    if (real == null) return;
    await _pulse.moveOwnStreams(
        capture: false, deviceId: '$pulseDevicePrefix$real');
    final sinks = await _pulse.pactl(['-f', 'json', 'list', 'sinks']);
    final inputs = await _pulse.pactl(['-f', 'json', 'list', 'sink-inputs']);
    if (sinks == null || inputs == null) return;
    final realIndex = sinkIndexOf(sinks, real);
    if (realIndex == null) return;
    for (final id in foreignStreamsOn(inputs, realIndex, _pulse.processId)) {
      await _pulse.pactl(['move-sink-input', '$id', _mixSink]);
    }
  }

  /// A crash can leave the previous mix loaded, which would capture twice.
  Future<void> _dropLeftovers() async {
    final loaded = await _pulse.pactl(['list', 'short', 'modules']);
    if (loaded == null) return;
    for (final id in moduleIdsMentioning(loaded, _mixSink)) {
      await _pulse.pactl(['unload-module', id]);
    }
  }

  Future<String?> _load(String module, List<String> args) async {
    final out = await _pulse.pactl(['load-module', module, ...args]);
    final id = out?.trim();
    return id == null || id.isEmpty ? null : id;
  }

  String? _strip(String? id) => id != null && id.startsWith(pulseDevicePrefix)
      ? id.substring(pulseDevicePrefix.length)
      : id;
}
