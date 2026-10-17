// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sound players that reach no platform channel.
library;

import 'package:slimm_app/src/audio/notification_sound.dart';

/// Plays nothing.
class SilentSoundPlayer implements SoundPlayer {
  @override
  Future<void> play(NotificationSound sound) async {}

  @override
  Future<void> loop(NotificationSound sound) async {}

  @override
  Future<void> stopLoop() async {}

  @override
  Future<void> dispose() async {}
}

/// Plays nothing and records what it was asked to play.
class RecordingSoundPlayer extends SilentSoundPlayer {
  final played = <NotificationSound>[];

  @override
  Future<void> play(NotificationSound sound) async => played.add(sound);
}
