// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/src/start_bitrate_peer_connection.dart';

class _RecordingConnection implements rtc.RTCPeerConnection {
  final remote = <rtc.RTCSessionDescription>[];

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription d) async {}

  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription d) async =>
      remote.add(d);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _offerWithHint = 'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'a=fmtp:96 x-google-start-bitrate=2700';
const _answer = 'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'a=rtpmap:96 VP8/90000\r\n'
    'a=fmtp:96 level=1';

void main() {
  late _RecordingConnection inner;
  late StartBitratePeerConnection pc;

  setUp(() {
    inner = _RecordingConnection();
    pc = StartBitratePeerConnection(inner);
  });

  test('the answer to an offer with a hint carries the hint', () async {
    await pc.setLocalDescription(
      rtc.RTCSessionDescription(_offerWithHint, 'offer'),
    );
    await pc.setRemoteDescription(rtc.RTCSessionDescription(_answer, 'answer'));
    expect(inner.remote.single.sdp,
        contains('level=1;x-google-start-bitrate=2700'));
  });

  test('a second local offer without a hint does not drop it', () async {
    await pc.setLocalDescription(
      rtc.RTCSessionDescription(_offerWithHint, 'offer'),
    );
    await pc.setLocalDescription(rtc.RTCSessionDescription(_answer, 'offer'));
    await pc.setRemoteDescription(rtc.RTCSessionDescription(_answer, 'answer'));
    expect(inner.remote.single.sdp, contains('x-google-start-bitrate=2700'));
  });

  test('the hint is used once, so a later answer is untouched', () async {
    await pc.setLocalDescription(
      rtc.RTCSessionDescription(_offerWithHint, 'offer'),
    );
    await pc.setRemoteDescription(rtc.RTCSessionDescription(_answer, 'answer'));
    await pc.setRemoteDescription(rtc.RTCSessionDescription(_answer, 'answer'));
    expect(inner.remote.last.sdp, _answer);
  });

  test('an offer without a hint leaves the answer alone', () async {
    await pc.setLocalDescription(rtc.RTCSessionDescription(_answer, 'offer'));
    await pc.setRemoteDescription(rtc.RTCSessionDescription(_answer, 'answer'));
    expect(inner.remote.single.sdp, _answer);
  });

  test('a remote offer is never rewritten', () async {
    await pc.setLocalDescription(
      rtc.RTCSessionDescription(_offerWithHint, 'offer'),
    );
    await pc.setRemoteDescription(rtc.RTCSessionDescription(_answer, 'offer'));
    expect(inner.remote.single.sdp, _answer);
  });
}
