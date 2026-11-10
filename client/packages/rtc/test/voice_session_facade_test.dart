// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The session forwards each public member to the collaborator that owns it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/reconnect_fakes.dart';

void main() {
  late JoinedCall call;
  late VoiceSession session;

  setUp(() async {
    call = await JoinedCall.join();
    session = call.session;
  });

  tearDown(() => session.dispose());

  test('mutes and gains set on the session are read back from it', () async {
    await session.setLocallyMuted('ana', true);
    await session.setScreenAudioMuted('ana', true);
    await session.setVolumeFor('ana', 0.5);
    await session.setScreenVolumeFor('ana', 1.5);

    expect(session.isLocallyMuted('ana'), isTrue);
    expect(session.isScreenAudioMuted('ana'), isTrue);
    expect(session.volumeFor('ana'), 0.5);
    expect(session.screenVolumeFor('ana'), 1.5);
    expect(session.volumeFailureFor('ana'), isNull);
    expect(session.hasScreenAudio('ana'), isFalse);
  });

  test('deafening reaches the roster of the joined call', () async {
    expect(await session.setDeafened(true), isTrue);

    expect(session.deafened, isTrue);
    expect(session.participants.single.isDeafened, isTrue);
  });

  test('leaving clears deafen and the mutes but not the gain', () async {
    await session.setLocallyMuted('ana', true);
    await session.setVolumeFor('ana', 0.5);
    await session.setDeafened(true);

    await session.leave();

    expect(session.deafened, isFalse);
    expect(session.isLocallyMuted('ana'), isFalse);
    expect(session.volumeFor('ana'), 0.5);
    expect(session.participants, isEmpty);
  });

  test('speaking sensitivity and receive quality are accepted mid-call', () {
    session
      ..setSpeakingSensitivity(0.2)
      ..setReceiveVideoQuality(ReceiveVideoQuality.auto)
      ..setCameraQuality(CameraQuality.balanced);

    expect(session.participants.single.isLocal, isTrue);
  });

  test('a held enlarged tile releases once however often it is told to', () {
    final release = session.holdEnlargedVideo('camera:ana');

    release();
    release();

    expect(session.participants.single.isLocal, isTrue);
  });

  test('video interest and blocks are accepted with nobody to cull', () {
    session
      ..setVideoInterest({'camera:ana'})
      ..setVideoBlocked({'screen:ana'})
      ..setVideoInterest(null);

    expect(session.videoHealth.value, isEmpty);
  });

  test('the read-only views the app binds to are present', () {
    expect(session.state, VoiceSessionState.connected);
    expect(session.callStats, same(session.callStats));
    expect(session.health, same(session.health));
    expect(session.diagnostics, same(session.diagnostics));
    expect(session.supportsParticipantVolume, isTrue);
    expect(session.lastError, isNull);
    expect(session.lastDisconnect, isNull);
    expect(session.droppedWhileSharing, isFalse);
    expect(session.micStatus, MicStatus.ok);
    expect(session.micFailure, isNull);
  });
}
