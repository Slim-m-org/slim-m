// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of the image surfaces: the image menu (on an inline image,
/// over the viewer, with a kept original) and the fullscreen viewer (one
/// image, a gallery, a page still loading, a page that failed, zoomed). The
/// viewer floats over the conversation, so both themes show through its
/// scrim. PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise each
/// case asserts a clean layout.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_app/src/features/messages/widgets/image_export.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_media.dart';
import 'ui_review_messages_support.dart';

const _ada = 'user-ada';

class _Exporter implements ImageExporter {
  _Exporter({required this.phone});

  final bool phone;

  @override
  bool get canShare => phone;

  @override
  bool get savesToLibrary => phone;

  @override
  Future<void> share(
    Uint8List bytes, {
    required String filename,
    required String contentType,
    Rect? origin,
  }) async {}

  @override
  Future<bool> save(Uint8List bytes, {required String filename}) async => true;
}

Override _exporter(String viewport) => imageExporterProvider.overrideWithValue(
  _Exporter(phone: viewport == 'phone'),
);

final _harbour = imageAttachment('img-0', 'harbour-at-dawn.png');
const _kept = api.Attachment(
  id: 'img-0',
  filename: 'harbour-at-dawn.png',
  contentType: 'image/png',
  size: 184320,
  original: api.AttachmentOriginal(size: 9437184, filename: 'IMG_4471.HEIC'),
);
final _trio = [
  _harbour,
  imageAttachment('img-1', 'lighthouse.png'),
  imageAttachment('img-2', 'market-square.png'),
];

List<api.Message> _post(List<api.Attachment> images) => [
  reviewMessage(1, _ada, 'photos from the weekend'),
  reviewMessage(2, _ada, 'the harbour at dawn', attachments: images),
];

List<Override> _media(String viewport, {List<Override> more = const []}) => [
  _exporter(viewport),
  ...mediaOverrides({for (var i = 0; i < 3; i++) 'img-$i': photo(i)}),
  ...more,
];

Offset _middle(ReviewScene scene) =>
    scene.tester.view.physicalSize.center(Offset.zero);

/// A right-click on a pointer layout, a long press on a touch one.
Future<void> _openMenu(ReviewScene scene, Offset at, String viewport) async {
  if (viewport == 'phone') {
    await scene.tester.longPressAt(at);
  } else {
    await scene.tester.tapAt(
      at,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
  }
  await scene.frames(3);
}

Offset _inlineImage(ReviewScene scene) =>
    scene.tester.getCenter(find.byWidgetPredicate((w) => w is Image).last);

Future<void> _openViewer(
  ReviewScene scene,
  List<api.Attachment> images, {
  int index = 0,
}) async {
  unawaited(
    showFullscreenImage(
      scene.context,
      images: images,
      index: index,
      bytes: photo(index),
      messageId: 'r-2',
    ),
  );
  await scene.frames(3);
  await scene.decode();
}

Future<void> _step(ReviewScene scene) async {
  await scene.tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
  await scene.frames(3);
}

Future<void> _pinchOpen(ReviewScene scene) async {
  final at = _middle(scene);
  final left = await scene.tester.startGesture(at - const Offset(20, 0));
  final right = await scene.tester.startGesture(at + const Offset(20, 0));
  await scene.tester.pump();
  await left.moveBy(const Offset(-90, 0));
  await right.moveBy(const Offset(90, 0));
  await scene.tester.pump();
  await left.up();
  await right.up();
  await scene.frames(3);
}

Future<void> _capture(
  WidgetTester tester,
  String surface,
  String state,
  String viewport,
  List<api.Attachment> images, {
  required SceneStep act,
  List<Override> more = const [],
  SceneStep? release,
}) => captureMessages(
  tester,
  surface: surface,
  state: state,
  viewport: viewport,
  messages: _post(images),
  overrides: _media(viewport, more: more),
  act: act,
  release: release,
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    testWidgets('menu inline at $viewport', (tester) async {
      await _capture(tester, 'menu-image-actions', 'inline', viewport, [
        _harbour,
      ], act: (scene) => _openMenu(scene, _inlineImage(scene), viewport));
    });

    testWidgets('menu viewer at $viewport', (tester) async {
      await _capture(
        tester,
        'menu-image-actions',
        'viewer',
        viewport,
        [_harbour],
        act: (scene) async {
          await _openViewer(scene, [_harbour]);
          await _openMenu(scene, _middle(scene), viewport);
        },
      );
    });

    testWidgets('menu with original at $viewport', (tester) async {
      await _capture(tester, 'menu-image-actions', 'with-original', viewport, [
        _kept,
      ], act: (scene) => _openMenu(scene, _inlineImage(scene), viewport));
    });

    testWidgets('viewer single at $viewport', (tester) async {
      await _capture(tester, 'overlay-fullscreen-image', 'single', viewport, [
        _harbour,
      ], act: (scene) => _openViewer(scene, [_harbour]));
    });

    testWidgets('viewer gallery at $viewport', (tester) async {
      await _capture(
        tester,
        'overlay-fullscreen-image',
        'gallery',
        viewport,
        _trio,
        act: (scene) async {
          await _openViewer(scene, _trio);
          await _step(scene);
          await scene.decode();
        },
      );
    });

    testWidgets('viewer loading at $viewport', (tester) async {
      final original = Completer<Uint8List>();
      await _capture(
        tester,
        'overlay-fullscreen-image',
        'loading',
        viewport,
        _trio,
        more: [
          attachmentBytesProvider.overrideWith(
            (ref, id) async => id == 'img-1' ? await original.future : photo(0),
          ),
        ],
        act: (scene) async {
          await _openViewer(scene, _trio);
          await _step(scene);
        },
        release: (_) async => original.complete(photo(1)),
      );
    });

    testWidgets('viewer failed at $viewport', (tester) async {
      await _capture(
        tester,
        'overlay-fullscreen-image',
        'failed',
        viewport,
        _trio,
        more: [
          attachmentBytesProvider.overrideWith((ref, id) async {
            if (id != 'img-1') return photo(0);
            throw const api.TransportException('connection lost');
          }),
        ],
        act: (scene) async {
          await _openViewer(scene, _trio);
          await _step(scene);
        },
      );
    });

    testWidgets('viewer zoomed at $viewport', (tester) async {
      await _capture(
        tester,
        'overlay-fullscreen-image',
        'zoomed',
        viewport,
        [_harbour],
        act: (scene) async {
          await _openViewer(scene, [_harbour]);
          await _pinchOpen(scene);
        },
      );
    });
  }
}
