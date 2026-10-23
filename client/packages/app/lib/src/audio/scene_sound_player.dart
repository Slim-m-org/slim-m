// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turns a module's [NotesOp] into sound: renders it through `scene_synth.dart`
/// and plays the resulting PCM straight from memory, never through a file on
/// disk and never through an asset the module could have shipped itself - a
/// module emits notes, not audio.
///
/// [ModuleSceneView] decides *when* this may run (only as the direct result
/// of the viewer's own action; see [NotesOp]'s own doc comment), and
/// `module_command_output.dart` decides *whether* it may run at all (the
/// [moduleSoundSettingsProvider] toggle). This file only knows how.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/modules/widgets/module_scene.dart' show SceneNote;
import 'notification_sound.dart' show AudioPlayersSoundPlayer;
import 'scene_synth.dart' as scene_synth;
import '../features/voice/providers/voice_controller.dart';
import 'sound_audio_context.dart';
import 'sound_output_router.dart';

abstract class ModuleSoundPlayer {
  Future<void> playNotes(List<SceneNote> notes);
  Future<void> dispose();
}

/// Renders and plays over `audioplayers`, the same package and the same
/// "never take the call's audio focus" configuration
/// [AudioPlayersSoundPlayer] uses for notification chimes - see that class's
/// own doc comment for why.
class AudioPlayersModuleSoundPlayer implements ModuleSoundPlayer {
  AudioPlayersModuleSoundPlayer({this.afterPlay, bool Function()? inCall})
    : inCall = inCall ?? (() => false);

  /// Whether a call holds the audio session right now.
  final bool Function() inCall;

  /// Routes the clip's stream to the chosen speaker once it starts.
  final Future<void> Function()? afterPlay;

  /// Built on first use, for the GStreamer reason [AudioPlayersSoundPlayer] gives.
  AudioPlayer? _created;
  AudioPlayer get _player => _created ??= AudioPlayer();

  /// Rendering is arithmetic over tens of thousands of samples (up to
  /// `NotesOp.maxNotes` notes, each up to `maxNoteSeconds` long), so this runs
  /// off the UI isolate via `compute()` - the same reason module command
  /// execution itself is already an async round trip rather than inline work;
  /// nothing about a module's output should be able to cost a frame. Stops
  /// whatever is already sounding before playing the new clip, which is what
  /// keeps a fast run of actions from queuing sound faster than it can be
  /// heard: each new cue replaces the last rather than layering on top of it.
  @override
  Future<void> playNotes(List<SceneNote> notes) async {
    if (notes.isEmpty) return;
    final wav = await compute(_renderWav, [
      for (final note in notes) [note.frequency, note.start, note.seconds],
    ]);
    await _player.stop();
    await playQuietly(
      () => _player.play(
        BytesSource(wav, mimeType: 'audio/wav'),
        volume: AudioPlayersSoundPlayer.playbackVolume,
        ctx: soundAudioContext(inCall: inCall()),
      ),
    );
    unawaited(afterPlay?.call());
  }

  @override
  Future<void> dispose() async => _created?.dispose();
}

/// A top-level function, as `compute` requires: renders one WAV clip from
/// `[frequency, start, seconds]` triples rather than [SceneNote] instances,
/// since only primitive values are guaranteed cheap to copy across the
/// isolate boundary `compute` spawns this on.
Uint8List _renderWav(List<List<double>> notes) {
  final synthNotes = [
    for (final n in notes)
      scene_synth.SynthNote(frequency: n[0], start: n[1], seconds: n[2]),
  ];
  return scene_synth.encodeWav16(scene_synth.render(synthNotes));
}

/// One player for the whole signed-in session, matching
/// `notificationSoundControllerProvider`'s own lifetime and disposal shape.
final moduleSoundPlayerProvider = Provider<ModuleSoundPlayer>((ref) {
  final player = AudioPlayersModuleSoundPlayer(
    afterPlay: ref.read(soundOutputRouterProvider).followChosenOutput,
    inCall: () => ref.read(voiceControllerProvider).channelId != null,
  );
  ref.onDispose(player.dispose);
  return player;
});
