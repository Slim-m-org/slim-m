// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's scrollbar and its attachment uploads, driven through the
/// real widget tree.
///
/// What the owner reported, in order: the text field's scrollbar thumb sat
/// beside the text instead of on the bar's edge; a big upload showed only
/// "Uploading..." and took seconds to appear; an over-size file failed with a
/// truncated message and left nothing in the debug log. Under
/// SLIMM_UI_SNAPSHOTS it also writes pictures of each state.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/composer.dart';
import 'package:slimm_app/src/widgets/composer_attachments.dart';

import 'composer_harness.dart';
import 'ui_snapshot_support.dart';

const _desktop = Size(1000, 600);
const _phone = Size(390, 700);
const _iso = 'Win11_24H2_English_x64.iso';

/// Records the one rounded rect a scrollbar thumb is drawn as.
class _ThumbCanvas implements Canvas {
  RRect? thumb;

  @override
  void drawRRect(RRect rrect, Paint paint) => thumb = rrect;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A server that answers `/version` with [maxBytes] and fails or accepts
/// uploads, counting every upload it receives in [uploads].
api.SlimmApi Function(Ref) _server({
  int? maxBytes,
  bool failUploads = false,
  List<String>? uploads,
}) =>
    (ref) => api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: MockClient((request) async {
        if (request.url.path == '/version') {
          return http.Response(
            jsonEncode({
              'name': 'slim-m',
              'version': '1.0.0',
              'protocol': 1,
              'max_attachment_bytes': ?maxBytes,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && request.url.path == '/attachments') {
          uploads?.add(request.url.queryParameters['filename'] ?? '');
          if (failUploads) throw http.ClientException('connection reset');
          return http.Response(
            jsonEncode({
              'id': 'a1',
              'filename': request.url.queryParameters['filename'],
              'content_type': 'image/png',
              'size': 4,
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      }),
    );

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Composer)));

Future<void> _scrollField(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(TextField));
  final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await pointer.addPointer(location: center);
  addTearDown(pointer.removePointer);
  await tester.sendEventToBinding(
    PointerScrollEvent(position: center, scrollDelta: const Offset(0, 40)),
  );
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUpAll(loadRealFonts);

  late TextEditingController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpComposer(
    WidgetTester tester, {
    Size size = _desktop,
    Brightness brightness = Brightness.light,
    api.SlimmApi Function(Ref)? apiBuilder,
    List<Override> overrides = const [],
  }) async {
    await _size(tester, size);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.linux,
        brightness: brightness,
        apiBuilder: apiBuilder,
        extraOverrides: overrides,
      ),
    );
    await tester.pump();
  }

  for (final (name, size) in [('desktop', _desktop), ('phone', _phone)]) {
    for (final brightness in Brightness.values) {
      testWidgets('$name ${brightness.name}: the scrollbar thumb sits on the '
          "bar's right edge, past the icons", (tester) async {
        controller.text = List.generate(
          8,
          (i) => 'line ${i + 1} of a long message',
        ).join('\n');
        await pumpComposer(tester, size: size, brightness: brightness);
        await _scrollField(tester);

        final bar = find.byWidgetPredicate((w) => w is RawScrollbar);
        final scrollbar = tester.state(bar) as RawScrollbarState;
        final canvas = _ThumbCanvas();
        final box = tester.renderObject<RenderBox>(bar);
        // ignore: invalid_use_of_protected_member
        scrollbar.scrollbarPainter.paint(canvas, box.size);
        final thumb = canvas.thumb;
        expect(thumb, isNotNull, reason: 'a long field draws a thumb');

        final thumbRight = box.localToGlobal(Offset(thumb!.right, 0)).dx;
        final barRight = tester
            .getTopRight(find.byKey(const Key('composer-action-bar')))
            .dx;
        expect(
          barRight - thumbRight,
          lessThanOrEqualTo(6),
          reason: 'the thumb hugs the bar edge, not the text column',
        );
        final fieldRight = tester.getTopRight(find.byType(TextField)).dx;
        expect(thumbRight, greaterThan(fieldRight));
        await writeSnapshot(
          tester,
          'composer-long-text-$name-${brightness.name}',
        );
      });
    }
  }

  testWidgets('progress follows the bytes sent, and shows a size', (
    tester,
  ) async {
    final reports = <void Function(int)>[];
    final staging = AttachmentStagingController(
      upload: (body, filename, onProgress) {
        reports.add(onProgress);
        return Completer<api.Attachment>().future;
      },
    );
    addTearDown(staging.dispose);
    await pumpComposer(
      tester,
      overrides: [attachmentStagingProvider.overrideWith((ref, id) => staging)],
    );

    await staging.stage(Uint8List(1000), _iso);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('0% of 1000 B'), findsOneWidget);

    reports.single(250);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('25% of 1000 B'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.25,
    );

    reports.single(900);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('90% of 1000 B'), findsOneWidget);
  });

  testWidgets('a large pick shows at once and is never read into memory', (
    tester,
  ) async {
    var readWhole = false;
    final opened = Completer<void>();
    final staging = AttachmentStagingController(
      upload: (body, filename, onProgress) {
        expect(body.bytes, isNull, reason: 'a big body is streamed');
        opened.complete();
        return Completer<api.Attachment>().future;
      },
    );
    addTearDown(staging.dispose);

    final refusal = await staging.stageFile(
      FileSource(
        name: _iso,
        length: () async => 5800000000,
        readAll: () async {
          readWhole = true;
          return Uint8List(0);
        },
        openRead: () => const Stream.empty(),
      ),
    );

    expect(refusal, isNull);
    expect(readWhole, isFalse);
    expect(staging.items.single, isA<UploadingAttachment>());
    expect(staging.items.single.body.length, 5800000000);
    expect(opened.isCompleted, isTrue);
  });

  testWidgets('an over-size pick never starts an upload and names the limit', (
    tester,
  ) async {
    final uploads = <String>[];
    usePicker(FakePlatformFile('holiday.png', Uint8List(4000)));
    await pumpComposer(
      tester,
      apiBuilder: _server(maxBytes: 1024, uploads: uploads),
    );

    await tester.tap(attachButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(uploads, isEmpty);
    expect(
      find.textContaining("holiday.png is 3.9 KB, over this server's limit of"),
      findsOneWidget,
    );
    expect(find.textContaining('1.0 KB per file'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final events = _container(tester).read(debugLogProvider);
    expect(events.single.source, 'attachment');
    expect(events.single.detail, contains('1.0 KB'));
  });

  testWidgets('a file under the limit uploads normally', (tester) async {
    final uploads = <String>[];
    usePicker(FakePlatformFile('holiday.png', Uint8List(4)));
    await pumpComposer(
      tester,
      apiBuilder: _server(maxBytes: 1024, uploads: uploads),
    );

    await tester.tap(attachButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(uploads, ['holiday.png']);
  });

  testWidgets('a failed upload reads in full and lands in the debug log', (
    tester,
  ) async {
    usePicker(FakePlatformFile(_iso, Uint8List(4)));
    await pumpComposer(tester, apiBuilder: _server(failUploads: true));

    await tester.tap(attachButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    final message = find.textContaining('Could not attach the file');
    expect(message, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(message);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.text.toPlainText(), contains('Nothing was changed.'));

    final events = _container(tester).read(debugLogProvider);
    expect(events.single.source, 'attachment');
    expect(events.single.message, contains(_iso));
    expect(events.single.detail, contains('connection reset'));
    await writeSnapshot(tester, 'composer-upload-failed-desktop-light');
  });

  for (final (name, size) in [('desktop', _desktop), ('phone', _phone)]) {
    for (final brightness in Brightness.values) {
      testWidgets('captures: $name ${brightness.name} upload states', (
        tester,
      ) async {
        final reports = <void Function(int)>[];
        final staging = AttachmentStagingController(
          upload: (body, filename, onProgress) {
            reports.add(onProgress);
            return Completer<api.Attachment>().future;
          },
        );
        addTearDown(staging.dispose);
        await pumpComposer(
          tester,
          size: size,
          brightness: brightness,
          overrides: [
            attachmentStagingProvider.overrideWith((ref, id) => staging),
          ],
        );
        await staging.stageBody(
          AttachmentBody.stream(
            length: 5800000000,
            open: () => const Stream.empty(),
          ),
          _iso,
        );
        reports.single(2400000000);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        await writeSnapshot(
          tester,
          'composer-upload-progress-$name-${brightness.name}',
        );
      });

      testWidgets('captures: $name ${brightness.name} failed upload', (
        tester,
      ) async {
        usePicker(FakePlatformFile(_iso, Uint8List(4)));
        await pumpComposer(
          tester,
          size: size,
          brightness: brightness,
          apiBuilder: _server(failUploads: true),
        );
        final staging = _container(
          tester,
        ).read(attachmentStagingProvider('c1'));
        await staging.stage(Uint8List(4), _iso);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        await writeSnapshot(
          tester,
          'composer-upload-failed-$name-${brightness.name}',
        );
      });
    }
  }
}
