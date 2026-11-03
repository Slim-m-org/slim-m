// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/answer_start_bitrate.dart';

String _sdp(List<String> lines) => lines.join('\r\n');

void main() {
  group('startBitrateIn', () {
    test('reads the largest hint on a video codec', () {
      final offer = _sdp([
        'm=audio 9 UDP/TLS/RTP/SAVPF 111',
        'a=fmtp:111 minptime=10;x-google-start-bitrate=50',
        'm=video 9 UDP/TLS/RTP/SAVPF 96 97',
        'a=fmtp:96 x-google-start-bitrate=900',
        'a=fmtp:97 x-google-start-bitrate=2700',
      ]);
      expect(startBitrateIn(offer), 2700);
    });

    test('is null when the offer carries no hint', () {
      final offer = _sdp([
        'm=video 9 UDP/TLS/RTP/SAVPF 96',
        'a=fmtp:96 level-asymmetry-allowed=1',
      ]);
      expect(startBitrateIn(offer), isNull);
    });
  });

  group('withStartBitrate', () {
    final answer = _sdp([
      'm=audio 9 UDP/TLS/RTP/SAVPF 111',
      'a=rtpmap:111 opus/48000/2',
      'a=fmtp:111 minptime=10;useinbandfec=1',
      'm=video 9 UDP/TLS/RTP/SAVPF 96 97 108 109',
      'a=rtpmap:96 VP8/90000',
      'a=rtpmap:97 rtx/90000',
      'a=fmtp:97 apt=96',
      'a=rtpmap:108 H264/90000',
      'a=fmtp:108 packetization-mode=1',
      'a=rtpmap:109 red/90000',
    ]);

    test('extends an existing fmtp and adds one where a codec has none', () {
      final out = withStartBitrate(answer, 2500).split('\r\n');
      expect(
          out,
          contains(
              'a=fmtp:108 packetization-mode=1;x-google-start-bitrate=2500'));
      expect(out, contains('a=fmtp:96 x-google-start-bitrate=2500'));
    });

    test('leaves audio, repair and redundancy payloads alone', () {
      final out = withStartBitrate(answer, 2500).split('\r\n');
      expect(out, contains('a=fmtp:111 minptime=10;useinbandfec=1'));
      expect(out, contains('a=fmtp:97 apt=96'));
      expect(out.where((l) => l.startsWith('a=fmtp:109')), isEmpty);
    });

    test('does not repeat a hint the answer already carries', () {
      final once = withStartBitrate(answer, 2500);
      expect(withStartBitrate(once, 2000), once);
    });

    test('caps a larger request at the most the answer may ask for', () {
      final out = withStartBitrate(answer, 9000);
      expect(startBitrateIn(out), maxAnswerStartKbps);
    });

    test('round-trips through startBitrateIn', () {
      expect(startBitrateIn(withStartBitrate(answer, 2500)), 2500);
    });
  });
}
