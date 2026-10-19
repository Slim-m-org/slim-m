// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A platform with no audio devices, so a session suite never reaches libwebrtc's
/// own device list, which needs a plugin a plain test does not have.
library;

import 'package:slimm_rtc/rtc.dart';

class NoAudioDevices implements AudioDevices {
  const NoAudioDevices();

  @override
  Future<List<AudioDevice>> inputs() async => const [];
  @override
  Future<List<AudioDevice>> outputs() async => const [];
  @override
  Future<AudioDevice?> systemDefaultInput() async => null;
  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;
  @override
  Stream<void> get onChange => const Stream.empty();
}
