// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice upload marks its request, and the voice fields read back off the
/// attachment.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Uri get _base => Uri.parse('http://localhost:8080');

TokenPair _tokens() => const TokenPair(
      userId: 'user-1',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      accessExpiresAt: 0,
    );

void main() {
  test('a voice upload marks the request and reads the voice fields back',
      () async {
    Uri? sentUri;
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(tokens: _tokens()),
      httpClient: MockClient((request) async {
        sentUri = request.url;
        return http.Response(
          jsonEncode({
            'id': 'abcd',
            'filename': 'voice-message.ogg',
            'content_type': 'audio/ogg',
            'size': 3,
            'voice': true,
            'duration_ms': 4200,
            'waveform': List.filled(64, 255),
          }),
          201,
        );
      }),
    );
    final attachment = await api.uploadAttachment(
      [1, 2, 3],
      filename: 'voice-message.ogg',
      channelId: 'c1',
      voice: VoiceInfo(
        duration: const Duration(milliseconds: 4200),
        waveform: List.generate(64, (i) => i),
      ),
    );
    final query = sentUri!.queryParameters;
    expect(query['voice'], 'true');
    expect(query['duration_ms'], '4200');
    expect(query['waveform'], hasLength(128));
    expect(query['waveform']!.substring(0, 4), '0001');
    expect(query['channel_id'], 'c1');
    expect(attachment.voice!.duration, const Duration(milliseconds: 4200));
    expect(attachment.voice!.waveform, hasLength(64));
  });

  test('an ordinary attachment has no voice', () {
    final attachment = Attachment.fromJson({
      'id': 'x',
      'filename': 'a.ogg',
      'content_type': 'audio/ogg',
      'size': 1,
    });
    expect(attachment.voice, isNull);
  });
}
