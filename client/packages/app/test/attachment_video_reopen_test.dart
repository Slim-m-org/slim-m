// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native source hands libmpv one fixed bearer header, so a video opened
/// before the access token rotated must reopen with the current token when
/// playback starts; otherwise its next range request is a 401.
///
/// Like the sibling player test this needs a real libmpv, and it serves a
/// short generated WAV from a loopback server started inside the test.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/attachment_video_reopen.dart';
import 'package:slimm_app/src/widgets/attachment_video_source_io.dart';

const _video = api.Attachment(
  id: 'v1',
  filename: 'clip.wav',
  contentType: 'video/mp4',
  size: 80044,
);

Uint8List _wav() {
  const rate = 8000;
  const samples = rate * 5;
  final data = ByteData(44 + samples * 2);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return data.buffer.asUint8List();
}

api.TokenPair _tokens(String access) => api.TokenPair(
  userId: 'u',
  accessToken: access,
  refreshToken: 'r',
  accessExpiresAt: 0,
);

Future<void> waitFor(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(MediaKit.ensureInitialized);

  test('playing after the token rotated reopens with the new token', () async {
    final bytes = _wav();
    final seen = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      seen.add(req.headers.value('authorization') ?? '');
      req.response.headers.set('accept-ranges', 'none');
      req.response.headers.contentType = ContentType('audio', 'wav');
      req.response.headers.contentLength = bytes.length;
      req.response.add(bytes);
      req.response.close().catchError((_) {});
    });
    final session = api.SessionStore(tokens: _tokens('tokA'));
    final client = api.SlimmApi(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      session: session,
    );
    addTearDown(client.close);

    final player = Player();
    addTearDown(player.dispose);
    final platform = player.platform as dynamic;
    await platform.setProperty('vo', 'null');
    await platform.setProperty('ao', 'null');

    final source = createAttachmentVideoSource();
    final reopener = StaleTokenReopener(
      player: player,
      source: source,
      apiClient: client,
      attachment: _video,
      onFailure: () => fail('reopen failed'),
    )..start();
    addTearDown(reopener.dispose);

    await player.open(
      await source.open(
        apiClient: client,
        attachment: _video,
        onProgress: (_) {},
      ),
      play: false,
    );
    await waitFor(() => seen.contains('Bearer tokA'));
    expect(seen, contains('Bearer tokA'));

    session.set(_tokens('tokB'));
    await player.play();

    await waitFor(() => seen.contains('Bearer tokB'));
    expect(seen, contains('Bearer tokB'), reason: 'requests seen: $seen');
  });
}
