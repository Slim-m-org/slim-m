// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which of libwebrtc's microphone filters are on, for hosts with the native
/// capture chain. All on unless turned off here.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceProcessing;

import '../../../providers/providers.dart';
import 'voice_controller.dart';

const _echoKey = 'slimm.voice.echo_cancellation';
const _gainKey = 'slimm.voice.auto_gain';
const _suppressionKey = 'slimm.voice.webrtc_noise_suppression';

/// The persisted filters, for `VoiceControllerInputMixin.restoreVoiceProcessing`.
Future<VoiceProcessing> loadVoiceProcessing(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return VoiceProcessing(
    echoCancellation: prefs.getBool(_echoKey) ?? true,
    autoGainControl: prefs.getBool(_gainKey) ?? true,
    noiseSuppression: prefs.getBool(_suppressionKey) ?? true,
  );
}

class VoiceProcessingController extends StateNotifier<VoiceProcessing> {
  VoiceProcessingController(this._ref) : super(const VoiceProcessing()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final loaded = await loadVoiceProcessing(_ref);
    if (mounted) state = loaded;
  }

  /// Persists the change and reopens a live microphone with it.
  Future<void> set(VoiceProcessing next) async {
    state = next;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_echoKey, next.echoCancellation);
    await prefs.setBool(_gainKey, next.autoGainControl);
    await prefs.setBool(_suppressionKey, next.noiseSuppression);
    await _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setVoiceProcessing(next);
  }
}

final voiceProcessingProvider =
    StateNotifierProvider<VoiceProcessingController, VoiceProcessing>(
      VoiceProcessingController.new,
    );
