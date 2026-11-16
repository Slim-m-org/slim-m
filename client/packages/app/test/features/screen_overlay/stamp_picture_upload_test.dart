// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a picture into a stamp (decision 0121), and what a refusal tells
/// the person: one sentence each, never the server's own wording.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_stamp_sender.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_images.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_picture_upload.dart';

api.SlimmApi _client(http.Response Function(http.Request) answer) =>
    api.SlimmApi(
      baseUrl: Uri.parse('http://test.invalid'),
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 4102444800000,
        ),
      ),
      httpClient: MockClient((request) async => answer(request)),
    );

StampImageCache _cache() => StampImageCache(
  fetchStill: (_) => throw UnimplementedError(),
  fetchOriginal: (_) => throw UnimplementedError(),
  customEmojiBytes: (_) => throw UnimplementedError(),
  customIndex: () => const {},
);

void main() {
  test('a picture over 8 MiB is refused before anything is uploaded', () async {
    var uploads = 0;
    final client = _client((_) {
      uploads++;
      return http.Response('{}', 200);
    });
    await expectLater(
      uploadStampPicture(
        client,
        _cache(),
        Uint8List(stampPictureMaxBytes + 1),
        filename: 'big.png',
      ),
      throwsA(
        isA<StampPictureRefused>().having(
          (r) => r.message,
          'message',
          'That picture is too large to stamp.',
        ),
      ),
    );
    expect(uploads, 0);
  });

  test('an upload the server refuses says why in plain words', () async {
    final client = _client((_) => http.Response('{"error":"too big"}', 413));
    await expectLater(
      uploadStampPicture(client, _cache(), Uint8List(10), filename: 'a.png'),
      throwsA(
        isA<StampPictureRefused>().having(
          (r) => r.message,
          'message',
          'That picture is too large to stamp.',
        ),
      ),
    );
  });

  test('a GIF animates on tiles only up to 4 MiB', () {
    api.Attachment gif(int size) => api.Attachment.fromJson({
      'id': 'a',
      'filename': 'a.gif',
      'content_type': 'image/gif',
      'size': size,
      'created_at': 0,
    });
    expect(stampAnimates(gif(stampAnimatedMaxBytes)), isTrue);
    expect(stampAnimates(gif(stampAnimatedMaxBytes + 1)), isFalse);
  });

  test('each refusal reads as one plain sentence', () {
    expect(
      stampRefusal(const api.RateLimitedException('slow')),
      'Wait a moment before stamping again.',
    );
    expect(
      stampRefusal(const api.ForbiddenException('Join the call to stamp')),
      'Join the call to stamp.',
    );
    expect(
      stampRefusal(const api.ForbiddenException('forbidden')),
      'You cannot stamp on this screen.',
    );
    expect(
      stampRefusal(const api.ConflictException('nope')),
      'Their screen is not taking stamps right now.',
    );
    expect(
      stampRefusal(
        const api.BadRequestException('a stamp picture must be at most 8 MiB'),
      ),
      'That picture is too large to stamp.',
    );
    expect(
      stampRefusal(const api.NotFoundException('attachment not found')),
      'That picture cannot be stamped.',
    );
  });
}
