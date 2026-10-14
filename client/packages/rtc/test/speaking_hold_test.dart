// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The speaking ring's short hold after speech stops.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/speaking_hold.dart';
import 'package:slimm_rtc/src/voice_models.dart';

VoiceParticipant _p(
  String id, {
  bool speaking = false,
  bool muted = false,
  bool local = false,
}) =>
    VoiceParticipant(
      identity: id,
      name: id,
      isSpeaking: speaking,
      isMuted: muted,
      isLocal: local,
      isScreenSharing: false,
    );

void main() {
  late DateTime now;
  late SpeakingHold hold;
  setUp(() {
    now = DateTime(2026);
    hold = SpeakingHold(clock: () => now);
  });

  test('a ring stays lit for the hold, then drops', () {
    hold.apply([_p('kiki', speaking: true)]);
    now = now.add(const Duration(milliseconds: 100));
    final (held, recheck) = hold.apply([_p('kiki')]);
    expect(held.single.isSpeaking, isTrue);
    expect(recheck, const Duration(milliseconds: 200));

    now = now.add(const Duration(milliseconds: 250));
    final (dropped, none) = hold.apply([_p('kiki')]);
    expect(dropped.single.isSpeaking, isFalse);
    expect(none, isNull);
  });

  test('muting ends the ring at once', () {
    hold.apply([_p('kiki', speaking: true)]);
    now = now.add(const Duration(milliseconds: 50));
    final (out, recheck) = hold.apply([_p('kiki', muted: true)]);
    expect(out.single.isSpeaking, isFalse);
    expect(recheck, isNull);
  });

  test('the local ring is left to the input gate when it has one', () {
    hold.apply([_p('me', speaking: true, local: true)]);
    now = now.add(const Duration(milliseconds: 50));
    final (gated, _) = hold.apply([_p('me', local: true)], skipLocal: true);
    expect(gated.single.isSpeaking, isFalse);
    final (ungated, _) = hold.apply([_p('me', local: true)]);
    expect(ungated.single.isSpeaking, isTrue);
  });

  test('someone who left is forgotten', () {
    hold.apply([_p('kiki', speaking: true)]);
    hold.apply(const []);
    now = now.add(const Duration(milliseconds: 50));
    final (out, _) = hold.apply([_p('kiki')]);
    expect(out.single.isSpeaking, isFalse);
  });
}
