// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The progress, volume and seek half of the hold-music player seams, for the
/// test fakes that only care about start and stop.
library;

import 'package:flutter/foundation.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';

mixin HoldPlaybackFake {
  final playbackNotifier = ValueNotifier(HoldPlayback.idle);
  final volumes = <double>[];
  final seeks = <Duration>[];

  ValueListenable<HoldPlayback> get playback => playbackNotifier;

  Future<void> setVolume(double volume) async => volumes.add(volume);

  Future<void> seek(Duration position) async => seeks.add(position);
}
