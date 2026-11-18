// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An inline gif is the same size focused and unfocused, and a held gif is
/// the size it plays at: the owner saw one grow each time the window lost
/// focus, and the transcript around it jumped.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

const _gif = api.Attachment(
  id: 'g1',
  filename: 'patrick.gif',
  contentType: 'image/gif',
  size: 20800,
);

const _viewKey = Key('focus-size-attachment');

/// Smaller than the inline cap and far smaller than the decode width, the
/// shape of a typical reaction gif.
const _width = 220;
const _height = 165;

/// A real gif whose logical screen is [_width] x [_height].
Uint8List _gifOfSize() {
  final bytes = base64Decode(
    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
  );
  ByteData.sublistView(bytes)
    ..setUint16(6, _width, Endian.little)
    ..setUint16(8, _height, Endian.little);
  return bytes;
}

/// The first-frame still the server answers for a gif it can shrink.
Future<Uint8List> _stillOfSize(WidgetTester tester) async {
  late Uint8List png;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, _width.toDouble(), _height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFE06C9F),
    );
    final image = await recorder.endRecording().toImage(_width, _height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    png = data!.buffer.asUint8List();
  });
  return png;
}

ProviderContainer _container({
  required Uint8List preview,
  Uint8List? original,
}) {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      attachmentPreviewBytesProvider.overrideWith((ref, key) async => preview),
      attachmentBytesProvider(
        _gif.id,
      ).overrideWith((ref) async => original ?? preview),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

final _painted = find.descendant(
  of: find.byKey(_viewKey),
  matching: find.byWidgetPredicate((w) => w is RawImage && w.image != null),
);

/// Pumps until a decoded frame is on screen, then returns the attachment's size.
Future<Size> _settledSize(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (_painted.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 50));
      return tester.getSize(find.byKey(_viewKey));
    }
  }
  fail('no frame of the gif was ever painted');
}

Future<void> _mount(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: AttachmentView(key: _viewKey, attachment: _gif),
          ),
        ),
      ),
    ),
  );
}

void _setFocused(bool focused) =>
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      focused ? AppLifecycleState.resumed : AppLifecycleState.inactive,
    );

void main() {
  setUp(() => addTearDown(() => _setFocused(true)));

  testWidgets('a playing gif keeps its size while the window is unfocused', (
    tester,
  ) async {
    final container = _container(preview: _gifOfSize());
    await _mount(tester, container);
    final focused = await _settledSize(tester);

    _setFocused(false);
    final unfocused = await _settledSize(tester);
    _setFocused(true);
    final refocused = await _settledSize(tester);

    expect(unfocused, focused);
    expect(refocused, focused);
  });

  testWidgets('losing focus pauses the frame on screen, with no gap', (
    tester,
  ) async {
    final container = _container(preview: _gifOfSize());
    await _mount(tester, container);
    final focused = await _settledSize(tester);

    _setFocused(false);
    await tester.pump();

    expect(_painted, findsOneWidget, reason: 'no placeholder while it swaps');
    expect(tester.getSize(find.byKey(_viewKey)), focused);
  });

  testWidgets('a gif shown by its still keeps its size as it starts to play', (
    tester,
  ) async {
    final container = _container(
      preview: await _stillOfSize(tester),
      original: _gifOfSize(),
    );
    _setFocused(false);
    await _mount(tester, container);
    final still = await _settledSize(tester);

    _setFocused(true);
    final playing = await _settledSize(tester);
    _setFocused(false);
    final paused = await _settledSize(tester);

    expect(playing, still);
    expect(paused, still);
  });

  testWidgets('a gif held for a tap is the size it plays at', (tester) async {
    final container = _container(
      preview: await _stillOfSize(tester),
      original: _gifOfSize(),
    );
    await container
        .read(gifAutoplayControllerProvider.notifier)
        .select(GifAutoplay.tapToPlay);
    await _mount(tester, container);
    final held = await _settledSize(tester);

    await tester.tap(find.byIcon(AppIcons.play));
    final revealed = await _settledSize(tester);

    expect(revealed, held);
  });

  testWidgets('a small gif is drawn at its own size, not stretched', (
    tester,
  ) async {
    final container = _container(preview: _gifOfSize());
    _setFocused(false);
    await _mount(tester, container);
    await _settledSize(tester);

    expect(
      tester.getSize(_painted.first),
      Size(_width.toDouble(), _height.toDouble()),
    );
  });
}
