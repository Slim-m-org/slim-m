// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which noise suppression the microphone uses on a host with the native
/// capture chain: libwebrtc's own (standard), rnnoise ahead of it (strong),
/// or DeepFilterNet with rnnoise beside it (strongest, Linux and Windows).
/// "Space default" follows the Space's choice on `/version`, which is only
/// ever Standard or Strong.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show supportsStrongestNoiseSuppression;

import '../../../providers/providers.dart';
import 'voice_controller.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

enum NoiseSuppressionChoice {
  spaceDefault('space'),
  standard('standard'),
  strong('strong'),
  strongest('strongest');

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
    strong || strongest => true,
  };

  /// Whether DeepFilterNet is asked for. A host that cannot run it gets
  /// Strong instead, so a saved Strongest never leaves a call with less.
  bool isStrongest({required bool supported}) => this == strongest && supported;

  /// What the picker offers: Strongest only where it can run.
  static List<NoiseSuppressionChoice> offered({required bool supported}) => [
    for (final choice in values)
      if (choice != strongest || supported) choice,
  ];
}

/// Whether this host can run Strongest; a provider so tests can override it.
final strongestSupportedProvider = Provider<bool>(
  (ref) => supportsStrongestNoiseSuppression,
);

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
    _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setNoiseSuppression(choice);
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
