// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `insecureSfuReason` is the guard that stops an operator's plaintext LAN
/// voice setting from quietly reaching a public deployment, where a call would
/// send microphone and screen-share media across the network in the clear with
/// nothing on screen to say so. It is a pure function off an untrusted wire
/// value (`token.url`), so its whole job is which addresses it refuses - and it
/// had no test.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_sfu_security.dart';

void main() {
  group('joining is allowed (no reason returned)', () {
    for (final url in [
      // Encrypted, so allowed even to a public deployment.
      'wss://livekit.example.com',
      'https://livekit.example.com:7880',
      // Plaintext but on a LAN, the self-hosted case the server itself permits.
      'ws://localhost:7880',
      'ws://192.168.1.50:7880',
      'ws://10.0.0.5:7880',
      'ws://172.16.4.4:7880',
      'http://voice.local',
    ]) {
      test(url, () => expect(insecureSfuReason(url), isNull));
    }
  });

  group('joining is refused (a reason returned)', () {
    for (final url in [
      // The case this exists for: plaintext media to a public address.
      'ws://livekit.example.com',
      'ws://livekit.example.com:7880',
      'http://8.8.8.8:7880',
      // 172.32 is outside the 172.16/12 private range, so it is public.
      'ws://172.32.0.1:7880',
      // An unknown scheme is neither encrypted nor a known plaintext one.
      'ftp://livekit.example.com',
      // Unparseable or scheme-less falls through to the refusal: fail closed.
      '',
      'livekit.example.com:7880',
    ]) {
      test(url.isEmpty ? '(empty)' : url, () {
        expect(insecureSfuReason(url), isNotNull);
      });
    }
  });
}
