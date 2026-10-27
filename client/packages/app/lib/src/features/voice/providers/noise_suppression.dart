// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which noise suppression the microphone uses on a host with the native
/// capture chain: libwebrtc's own (standard), or rnnoise ahead of it
/// (strong). "Space default" follows the Space's choice on `/version`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import 'voice_controller.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

enum NoiseSuppressionChoice {
  spaceDefault('space'),
  standard('standard'),
  strong('strong');

  const NoiseSuppressionChoice(this.wire);

  final String wire;

  static NoiseSuppressionChoice parse(String? raw) => values.firstWhere(
    (choice) => choice.wire == raw,
    orElse: () => spaceDefault,
  );

  /// Whether this choice means rnnoise runs, given the Space's default.
  bool isStrong({required bool spaceStrong}) => switch (this) {
    spaceDefault => spaceStrong,
    standard => false,
    strong => true,
  };
}

const _choiceKey = 'slimm.voice.noise_suppression';

/// The persisted choice, for `VoiceControllerInputMixin.restoreNoiseSuppression`.
Future<NoiseSuppressionChoice> loadNoiseSuppressionChoice(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return NoiseSuppressionChoice.parse(prefs.getString(_choiceKey));
}

/// Whether the Space defaults to strong suppression, or null when the server
/// cannot say, so a caller keeps what it last knew rather than guessing.
Future<bool?> fetchSpaceStrongNoiseSuppression(Ref ref) async {
  try {
    return (await ref.read(apiProvider).version()).strongNoiseSuppression;
  } on Object catch (error, stack) {
    reportFailure(
      LogTag.voice,
      "read the server's noise suppression default",
      error,
      stack,
    );
    return null;
  }
}

class NoiseSuppressionController extends StateNotifier<NoiseSuppressionChoice> {
  NoiseSuppressionController(this._ref)
    : super(NoiseSuppressionChoice.spaceDefault) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final loaded = await loadNoiseSuppressionChoice(_ref);
    if (mounted) state = loaded;
  }

  /// Persists the choice and applies it live.
  Future<void> set(NoiseSuppressionChoice choice) async {
    state = choice;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(_choiceKey, choice.wire);
    _ref.read(voiceControllerProvider.notifier).setNoiseSuppression(choice);
  }
}

final noiseSuppressionProvider =
    StateNotifierProvider<NoiseSuppressionController, NoiseSuppressionChoice>(
      NoiseSuppressionController.new,
    );

/// The Space's default, for the settings card to say what "Space default"
/// currently means.
final spaceStrongNoiseSuppressionProvider = FutureProvider.autoDispose<bool>(
  (ref) async => await fetchSpaceStrongNoiseSuppression(ref) ?? false,
);
