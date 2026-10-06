// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasImageHydrator] against the lifecycle the document puts its images
/// through: removal, restore and a hard reset free or replace a bitmap, and
/// the decode budget has to follow what the document actually holds, not what
/// the hydrator remembers having done.
library;

import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_image_hydrator.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/synthetic_png.dart';

Future<void> _settleUntil(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _Rig {
  _Rig({this.bytes, this.maxDecodedBytes = defaultMaxDecodedImageBytes}) {
    final png = bytes ?? solidPng(8, 8);
    document = CanvasDocument()..setViewport(const Size(400, 400));
    hydrator = CanvasImageHydrator(
      client: api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
        httpClient: MockClient((request) async {
          fetched.add(request.url.pathSegments.last);
          return http.Response.bytes(
            png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      ),
      document: document,
      maxDecodedBytes: maxDecodedBytes,
    );
  }

  final Uint8List? bytes;
  final int maxDecodedBytes;
  late final CanvasDocument document;
  late final CanvasImageHydrator hydrator;
  final fetched = <String>[];

  CanvasStrokeInput input(String id, {double x = 0, double y = 0}) =>
      CanvasStrokeInput(
        id: id,
        seq: 1,
        zIndex: 1,
        x: x,
        y: y,
        w: 20,
        h: 20,
        points: const [],
        width: 0,
        colorKey: '',
        kind: CanvasObjectKind.image,
        attachmentId: 'att-$id',
      );

  api.CanvasObject wire(String id, {double x = 0, double y = 0}) =>
      api.CanvasObject(
        id: id,
        kind: 'image',
        zIndex: 1,
        x: x,
        y: y,
        w: 20,
        h: 20,
        props: {'attachment': 'att-$id', 'content_type': 'image/png'},
        authorId: 'someone-else',
        seq: 1,
        createdAt: 0,
      );

  /// What a viewport page does for each object: place it, then hydrate it.
  void arrive(String id, {double x = 0, double y = 0}) {
    document
      ..applyPlaced(input(id, x: x, y: y))
      ..refresh();
    hydrator.hydrate(wire(id, x: x, y: y));
  }

  bool has(String id) => document.hasImageBitmap(id);

  void dispose() {
    hydrator.dispose();
    document.dispose();
  }
}

void main() {
  test('a restored image is fetched again', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    rig.arrive('a');
    await _settleUntil(() => rig.has('a'));
    expect(rig.fetched, hasLength(1));

    rig.document
      ..removeObject('a')
      ..forgetRemoved(['a']);
    rig.arrive('a');
    await _settleUntil(() => rig.has('a'));

    expect(rig.fetched, hasLength(2), reason: 'restored image must refetch');
    expect(rig.has('a'), isTrue);
  });

  test('an image arriving after a hard reset is fetched again', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    rig.arrive('a');
    await _settleUntil(() => rig.has('a'));

    rig.document.reset();
    rig.arrive('a');
    await _settleUntil(() => rig.has('a'));

    expect(rig.has('a'), isTrue, reason: 'bitmap after hard reset');
  });

  test('a restored image whose first fetch failed is tried again', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    rig.document
      ..applyPlaced(rig.input('a'))
      ..refresh()
      ..markImageLoadFailed('a');
    rig.hydrator.hydrate(rig.wire('a'));
    await pumpEventQueue();
    expect(rig.fetched, isEmpty, reason: 'a failed image is not retried');

    rig.document
      ..removeObject('a')
      ..forgetRemoved(['a']);
    rig.arrive('a');
    await _settleUntil(() => rig.has('a'));

    expect(rig.has('a'), isTrue);
  });

  test('a removed image stops counting against the decode budget', () async {
    // 8x8 rgba is 256 bytes; the budget holds two of them.
    final rig = _Rig(maxDecodedBytes: 512);
    addTearDown(rig.dispose);
    rig.arrive('off', x: 5000, y: 5000);
    await _settleUntil(() => rig.has('off'));
    rig.arrive('b', x: 30);
    await _settleUntil(() => rig.has('b'));

    rig.document.removeObject('b');
    rig.arrive('c', x: 60);
    await _settleUntil(() => rig.has('c'));

    expect(
      rig.has('off'),
      isTrue,
      reason: 'only off and c are alive, they fit',
    );
    expect(rig.has('c'), isTrue);
  });

  test('a huge photo is decoded at a bounded size', () async {
    final rig = _Rig(bytes: solidPng(4032, 3024));
    addTearDown(rig.dispose);
    rig.arrive('a');
    await _settleUntil(() => rig.has('a'));

    final image = rig.document.strokeIfAlive(rig.document.slotOf('a')!)!.image!;
    expect(
      image.width > image.height ? image.width : image.height,
      lessThanOrEqualTo(maxHydratedImageSide),
    );
    expect(image.width / image.height, closeTo(4032 / 3024, 0.01));
  });

  test('two huge photos both keep a bitmap after a refetch', () async {
    final rig = _Rig(bytes: solidPng(4032, 3024));
    addTearDown(rig.dispose);
    rig.arrive('a', x: 0);
    await _settleUntil(() => rig.has('a'));
    rig.arrive('b', x: 30);
    await _settleUntil(() => rig.has('b'));
    rig.hydrator
      ..hydrate(rig.wire('a', x: 0))
      ..hydrate(rig.wire('b', x: 30));
    await pumpEventQueue();

    expect(rig.has('a') && rig.has('b'), isTrue);
    expect(rig.fetched, hasLength(2), reason: 'neither was evicted');
  });

  test('over budget, the image on screen stays and the one off screen goes '
      'first', () async {
    final rig = _Rig(maxDecodedBytes: 512);
    addTearDown(rig.dispose);
    rig.arrive('a', x: 0);
    await _settleUntil(() => rig.has('a'));
    rig.arrive('far', x: 5000, y: 5000);
    await _settleUntil(() => rig.has('far'));
    rig.arrive('b', x: 30);
    await _settleUntil(() => rig.has('b'));

    expect(rig.has('a'), isTrue);
    expect(rig.has('b'), isTrue);
    expect(rig.has('far'), isFalse, reason: 'off screen, so evicted first');
  });

  test('everything on screen is kept even past the budget', () async {
    final rig = _Rig(maxDecodedBytes: 256);
    addTearDown(rig.dispose);
    for (final (i, id) in ['a', 'b', 'c'].indexed) {
      rig.arrive(id, x: i * 30.0);
      await _settleUntil(() => rig.has(id));
    }

    expect([rig.has('a'), rig.has('b'), rig.has('c')], everyElement(isTrue));
    expect(rig.fetched, hasLength(3), reason: 'nothing thrashes');
  });

  test(
    'an image evicted off screen comes back when the view reaches it',
    () async {
      final rig = _Rig(maxDecodedBytes: 256);
      addTearDown(rig.dispose);
      rig.arrive('far', x: 5000, y: 5000);
      await _settleUntil(() => rig.has('far'));
      rig.arrive('a', x: 0);
      await _settleUntil(() => rig.has('a'));
      expect(rig.has('far'), isFalse);

      rig.document
        ..setCamera(const Camera(x: 4900, y: 4900, zoom: 1))
        ..refresh();
      rig.hydrator.hydrateVisible();
      await _settleUntil(() => rig.has('far'));

      expect(rig.has('far'), isTrue);
      expect(rig.fetched.where((id) => id == 'att-far'), hasLength(2));
    },
  );

  test('hydrateVisible fetches nothing for an image that already has its '
      'bitmap', () async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    rig.arrive('a');
    await _settleUntil(() => rig.has('a'));

    rig.hydrator.hydrateVisible();
    await pumpEventQueue();

    expect(rig.fetched, hasLength(1));
  });
}
