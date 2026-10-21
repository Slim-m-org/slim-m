// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_rtc/rtc.dart';

VoiceParticipant _p({
  double level = 0,
  bool speaking = false,
  bool camera = false,
  bool deafened = false,
}) => VoiceParticipant(
  identity: 'u1',
  name: 'Riley',
  audioLevel: level,
  isSpeaking: speaking,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: camera,
  isDeafened: deafened,
);

void main() {
  test('a speaking level change alone does not rebuild the canvas', () {
    expect(
      CanvasCallParticipants([_p(level: 0.1)]),
      CanvasCallParticipants([_p(level: 0.9)]),
    );
  });

  test('starting or stopping speech does not rebuild the canvas either', () {
    expect(
      CanvasCallParticipants([_p()]),
      CanvasCallParticipants([_p(speaking: true)]),
    );
  });

  test('anything the canvas draws still counts as a change', () {
    expect(
      CanvasCallParticipants([_p()]),
      isNot(CanvasCallParticipants([_p(camera: true)])),
    );
    expect(
      CanvasCallParticipants([_p()]),
      isNot(CanvasCallParticipants([_p(deafened: true)])),
    );
    expect(
      CanvasCallParticipants([_p()]),
      isNot(const CanvasCallParticipants([])),
    );
  });
}
