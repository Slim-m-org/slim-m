// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a picture into a stamp (decision 0121), and what a refusal tells
/// the person: one sentence each, never the server's own wording.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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

/// A picture of noise, which PNG cannot squeeze: a screenshot of a busy screen is as heavy.
Future<Uint8List> _noisyPng(int width, int height) async {
  final random = math.Random(7);
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = i % 4 == 3 ? 255 : random.nextInt(256);
  }
  final decoded = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    decoded.complete,
  );
  final image = await decoded.future;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

Future<(int, int)> _sizeOf(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final size = (image.width, image.height);
  image.dispose();
  codec.dispose();
  return size;
}

StampImageCache _cache() => StampImageCache(
  fetchStill: (_) => throw UnimplementedError(),
  fetchOriginal: (_) => throw UnimplementedError(),
  customEmojiBytes: (_) => throw UnimplementedError(),
  customIndex: () => const {},
);

void main() {
  test(
    'a screenshot past 8 MiB goes up shrunk to a PNG rather than refused',
    () async {
      final screenshot = await _noisyPng(2400, 1500);
      expect(screenshot.length, greaterThan(stampPictureMaxBytes));
      http.Request? upload;
      final client = _client((request) {
        upload = request;
        return http.Response(
          '{"id":"att","filename":"shot.png","content_type":"image/png",'
          '"size":${request.bodyBytes.length},"created_at":0}',
          201,
          headers: const {'content-type': 'application/json'},
        );
      });
      final stamp = await uploadStampPicture(
        client,
        _cache(),
        screenshot,
        filename: 'Screenshot_20261120.jpeg',
      );
      expect(stamp.attachmentId, 'att');
      final sent = upload!;
      expect(sent.url.queryParameters['filename'], 'Screenshot_20261120.png');
      expect(sent.bodyBytes.length, lessThanOrEqualTo(stampPictureMaxBytes));
      expect(await _sizeOf(sent.bodyBytes), (stampShrinkEdge, 640));
    },
  );

  test('a file past 8 MiB that is no picture is refused unsent', () async {
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
          'That picture could not be read.',
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
      stampRefusal(
        const api.BadRequestException(
          'a stamp picture must be at most 40 megapixels',
        ),
      ),
      'That picture is too large to stamp.',
    );
    expect(
      stampRefusal(
        const api.BadRequestException(
          'a stamped GIF must keep every frame inside its picture',
        ),
      ),
      'That GIF cannot be stamped.',
    );
    expect(
      stampRefusal(const api.NotFoundException('attachment not found')),
      'That picture cannot be stamped.',
    );
  });
}
