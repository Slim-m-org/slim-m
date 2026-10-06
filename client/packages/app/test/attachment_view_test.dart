// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An inline attachment image must never be asked to decode wider than it can
/// ever be drawn: a phone photo attached to a message is routinely megabytes
/// at full resolution, and the transcript never shows more than
/// [kInlineImageMax] logical pixels of it - half the message column, since an
/// uncapped preview filled a desktop screen and pushed the conversation off
/// it.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/attachment_bytes.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/attachment_video_player.dart';
import 'package:slimm_app/src/widgets/attachment_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _attachment = api.Attachment(
  id: 'a1',
  filename: 'photo.png',
  contentType: 'image/png',
  size: 4,
);

Future<void> _pump(WidgetTester tester, Uint8List bytes) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        attachmentBytesProvider(
          _attachment.id,
        ).overrideWith((ref) async => bytes),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AttachmentView(attachment: _attachment)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Extends (never implements) [FilePickerPlatform]; see
/// `attachment_save_test.dart` for the same fake in isolation.
class _FakeSaver extends FilePickerPlatform {
  String? savedFileName;
  Uint8List? savedBytes;

  @override
  Future<Uri?> saveFile({
    String? dialogTitle,
    required String fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
    void Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    savedFileName = fileName;
    savedBytes = bytes;
    return Uri.file('/home/user/Downloads/$fileName');
  }
}

_FakeSaver _useSaver() {
  final previous = FilePickerPlatform.instance;
  final saver = _FakeSaver();
  FilePickerPlatform.instance = saver;
  addTearDown(() => FilePickerPlatform.instance = previous);
  return saver;
}

void main() {
  setUpAll(MediaKit.ensureInitialized);

  testWidgets('the decode width is capped at the inline max, scaled by dpr', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await _pump(tester, Uint8List.fromList(const [1, 2, 3, 4]));

    // cacheWidth/cacheHeight land on the provider as a ResizeImage, not Image.
    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    expect(resized.width, (kInlineImageMax * 2).round());
    // Null, so the codec keeps the source's own aspect ratio.
    expect(resized.height, isNull);
  });

  testWidgets('at 1x the cap is the inline max in real pixels', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(tester, Uint8List.fromList(const [5, 6, 7, 8]));

    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    expect(resized.width, kInlineImageMax.round());
  });

  testWidgets(
    'bytes a fetch succeeded on but the codec refuses to decode show this '
    'surface\'s own failure box, not Flutter\'s raw error widget',
    (tester) async {
      await _pump(tester, Uint8List.fromList(const [1, 2, 3, 4]));

      expect(find.byType(ErrorWidget), findsNothing);
      expect(
        find.text('Could not open ${_attachment.filename}.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a non-image chip with a long real filename elides instead of '
      'overflowing a phone-width column', (tester) async {
    const longName = api.Attachment(
      id: 'a2',
      filename: 'quarterly-report-final-v3-actually-final-honestly.pdf',
      contentType: 'application/pdf',
      size: 1800000,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: SizedBox(
              width: 342,
              child: AttachmentView(attachment: longName),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  const pdf = api.Attachment(
    id: 'p1',
    filename: 'report.pdf',
    contentType: 'application/pdf',
    size: 1800000,
  );

  testWidgets(
    'a non-image attachment exposes a save action that fetches with auth '
    'and hands off the exact bytes',
    (tester) async {
      final saver = _useSaver();
      final bytes = Uint8List.fromList(const [9, 9, 9]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            attachmentBytesProvider(pdf.id).overrideWith((ref) async {
              return bytes;
            }),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: AttachmentView(attachment: pdf)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(AppIcons.download), findsOneWidget);
      await tester.tap(find.text(pdf.filename));
      await tester.pumpAndSettle();

      expect(saver.savedFileName, pdf.filename);
      expect(saver.savedBytes, bytes);
    },
  );

  testWidgets(
    'a save failure surfaces through this row\'s own AppErrorState, never a '
    'SnackBar',
    (tester) async {
      _useSaver();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            attachmentBytesProvider(pdf.id).overrideWith((ref) async {
              throw const api.ForbiddenException('not in this channel');
            }),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: AttachmentView(attachment: pdf)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(pdf.filename));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.text(
          'Could not save ${pdf.filename}: you are not allowed to do that.',
        ),
        findsOneWidget,
      );
    },
  );

  test(
    'the four inline image types still render inline, nothing else does',
    () {
      for (final type in const [
        'image/png',
        'image/jpeg',
        'image/gif',
        'image/webp',
      ]) {
        expect(isInlineImage(type), isTrue, reason: type);
        expect(isVideo(type), isFalse, reason: type);
      }
      expect(isInlineImage('video/mp4'), isFalse);
      expect(isInlineImage('application/pdf'), isFalse);
    },
  );

  testWidgets('a video attachment routes to the inline player, not the chip', (
    tester,
  ) async {
    const video = api.Attachment(
      id: 'v1',
      filename: 'clip.mp4',
      contentType: 'video/mp4',
      size: 12000000,
    );
    // No sign-in: the player's own source rejects it before touching the network, so this settles rather than spinning forever.
    final signedOut = api.SlimmApi(baseUrl: Uri.parse('http://localhost:1'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(signedOut)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: AttachmentView(attachment: video)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentVideoPlayer), findsOneWidget);
  });
}
