// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Backlog #134: a chime must never play at the player's own full scale on
/// top of an already-normalised wav, so [AudioPlayersSoundPlayer] caps its
/// own playback volume rather than leaving `audioplayers`' default of 1.0.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/notification_sound.dart';

void main() {
  test('playback volume is capped well below full scale', () {
    expect(AudioPlayersSoundPlayer.playbackVolume, lessThan(1.0));
  });

  test('playback volume is not attenuated into inaudibility', () {
    expect(AudioPlayersSoundPlayer.playbackVolume, greaterThan(0.2));
  });
}
