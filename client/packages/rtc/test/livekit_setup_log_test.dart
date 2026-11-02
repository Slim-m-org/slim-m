// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// livekit_client's connection-setup time and start-bitrate hint reach the
/// call's diagnostics, and only those two lines do.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/livekit_setup_log.dart';

import 'support/session_fakes.dart';

void main() {
  test('the setup time and the start bitrate are told apart from the rest', () {
    expect(
      setupDiagnostic('livekit', 'connection setup took 812 ms'),
      'LiveKit: connection setup took 812 ms',
    );
    const applied = 'Applying x-google-start-bitrate=900 kbps '
        '(connection setup 812 ms)';
    expect(setupDiagnostic('livekit', applied), 'LiveKit: $applied');
    expect(setupDiagnostic('livekit', 'restarting ICE'), isNull);
    expect(setupDiagnostic('livekit', 'connection setup took long'), isNull);
    expect(setupDiagnostic('other', 'connection setup took 5 ms'), isNull);
  });

  test('a call copies them into its diagnostics until it ends', () async {
    final lines = <String>[];
    final session = VoiceSession(
      roomFactory: ConnectlessRoom.new,
      audioLog: (message, {level = LogLevel.info}) => lines.add(message),
      // The real device list warms up through flutter_webrtc after a leave, which needs a platform.
      audioDevices: NoDevices(),
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    lk.logger.info('connection setup took 100 ms');
    await Future<void>.delayed(Duration.zero);
    expect(lines.where((l) => l.startsWith('LiveKit:')), isEmpty);

    await session.join(
      url: 'wss://a.invalid',
      token: 't',
      microphoneEnabled: false,
    );
    lk.logger.info('connection setup took 812 ms');
    lk.logger.info(
      'Applying x-google-start-bitrate=900 kbps (connection setup 812 ms)',
    );
    await Future<void>.delayed(Duration.zero);
    await session.leave();
    lk.logger.info('connection setup took 999 ms');
    await Future<void>.delayed(Duration.zero);

    expect(lines.where((l) => l.startsWith('LiveKit:')), [
      'LiveKit: connection setup took 812 ms',
      'LiveKit: Applying x-google-start-bitrate=900 kbps '
          '(connection setup 812 ms)',
    ]);
  });
}
