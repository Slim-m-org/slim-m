// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas presence tiles are keyed by a `kind:identity` string built by one
/// shared builder and parsed back by another, and sized by kind and camera
/// state. A drift between build and parse, or a wrong size branch, silently
/// breaks every tile's placement, so this pins the round-trip and the sizes
/// without hardcoding the key format - it uses the real builder both ways.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';
import 'package:slimm_rtc/rtc.dart';

VoiceParticipant _p(
  String identity, {
  bool screen = false,
  bool camera = false,
}) => VoiceParticipant(
  identity: identity,
  name: identity,
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: screen,
  isCameraOn: camera,
);

void main() {
  test(
    'a participant with a camera gets one camera key that round-trips to their identity',
    () {
      final keys = presenceTileKeys([_p('user-1', camera: true)]);
      expect(keys, hasLength(1));
      final key = keys.single;
      expect(presenceTileIdentity(key), 'user-1');
      expect(presenceTileKind(key), 'camera');
    },
  );

  test('a screen sharer with a camera also gets a screen key', () {
    final keys = presenceTileKeys([_p('user-1', screen: true, camera: true)]);
    expect(keys, hasLength(2));
    expect(keys.map(presenceTileKind).toSet(), {'camera', 'screen'});
    expect(keys.map(presenceTileIdentity).toSet(), {'user-1'});
  });

  test('tile size follows the kind', () {
    final screenKey = presenceTileKeys([
      _p('a', screen: true),
    ]).firstWhere((k) => presenceTileKind(k) == 'screen');
    final cameraKey = presenceTileKeys([_p('b', camera: true)]).single;

    expect(presenceTileSize(screenKey), presenceScreenShareSize);
    expect(presenceTileSize(cameraKey), presenceCameraOnSize);
  });

  test('a person with neither a camera nor a share has no tile', () {
    expect(presenceTileKeys([_p('user-1')]), isEmpty);
  });

  test('a sharer with the camera off has only the screen tile', () {
    final keys = presenceTileKeys([_p('user-1', screen: true)]);
    expect(keys.map(presenceTileKind).toSet(), {'screen'});
  });
}
