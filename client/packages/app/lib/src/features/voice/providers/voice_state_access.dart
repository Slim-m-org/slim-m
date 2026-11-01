// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Read and write access to the controller's [VoiceState] for a collaborator.
library;

import 'voice_state.dart';

/// Handed to each collaborator the controller composes, so none of them
/// needs a reference to the controller itself.
class VoiceStateAccess {
  VoiceStateAccess({
    required VoiceState Function() read,
    required void Function(VoiceState) write,
  }) : _read = read,
       _write = write;

  final VoiceState Function() _read;
  final void Function(VoiceState) _write;

  VoiceState get state => _read();

  set state(VoiceState value) => _write(value);
}
