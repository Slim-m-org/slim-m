// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The camera picker and view glue of a voice session.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'camera_switching.dart';
import 'camera_view.dart';
import 'voice_models.dart';
import 'voice_session_screen_share.dart';

/// Lists, flips and selects cameras on the session's room, and renders them.
class VoiceCamera {
  VoiceCamera(this._host, this.switching, this._density);

  final VoiceScreenShareHost _host;
  final CameraSwitching switching;
  final ValueListenable<lk.AdaptiveStreamPixelDensity> _density;

  Future<List<CameraDevice>> devices() =>
      _host.reported('list cameras', const [], switching.devices);

  Future<bool> flip() => _host.reported(
        'switch the camera',
        false,
        () => switching.flip(_host.room()?.localParticipant),
      );

  Future<bool> select(CameraDevice device) async {
    final room = _host.room();
    if (room == null) return false;
    return _host.reported('choose the camera', false, () async {
      await switching.select(room, device);
      _host.refresh();
      return true;
    });
  }

  Widget view(String identity) {
    final room = _host.room();
    if (room == null) return const SizedBox.shrink();
    return CameraView(
      room: room,
      identity: identity,
      facing: switching.facing,
      density: _density,
    );
  }
}
