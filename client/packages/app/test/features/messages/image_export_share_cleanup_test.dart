// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sharing an image from bytes must not leave a copy in the temp directory.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:slimm_app/src/features/messages/widgets/image_export.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('slimm_share_test_');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> share(PlatformImageExporter exporter) => exporter.share(
    Uint8List.fromList([1, 2, 3]),
    filename: 'photo.png',
    contentType: 'image/png',
  );

  test(
    'the sheet is handed a real file, gone once the share completes',
    () async {
      String? seenPath;
      List<int>? seenBytes;
      await share(
        PlatformImageExporter(
          tempRoot: () async => root,
          shareFiles: (params) async {
            seenPath = params.files!.single.path;
            seenBytes = File(seenPath!).readAsBytesSync();
          },
        ),
      );

      expect(seenBytes, [1, 2, 3]);
      expect(seenPath, endsWith('/photo.png'));
      expect(root.listSync(), isEmpty);
    },
  );

  test('a failed share removes the file too and rethrows', () async {
    final exporter = PlatformImageExporter(
      tempRoot: () async => root,
      shareFiles: (ShareParams params) async => throw StateError('no sheet'),
    );

    await expectLater(share(exporter), throwsStateError);
    expect(root.listSync(), isEmpty);
  });

  test(
    'Android keeps the file for the target app, and the next share sweeps it',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final exporter = PlatformImageExporter(
        tempRoot: () async => root,
        shareFiles: (params) async {},
      );

      await share(exporter);
      final first = root.listSync().single.path;
      expect(File('$first/photo.png').existsSync(), isTrue);

      await share(exporter);
      expect(root.listSync().single.path, isNot(first));
    },
  );
}
