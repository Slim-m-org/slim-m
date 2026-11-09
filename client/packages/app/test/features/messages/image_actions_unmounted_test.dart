// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Copy and Save image outlive the widget that asked for them: the original
/// can take long enough to load that the row or viewer is gone by then.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/image_actions.dart';
import 'package:slimm_app/src/features/messages/widgets/image_export.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_platform/platform.dart';

const _image = api.Attachment(
  id: 'a1',
  filename: 'holiday.png',
  contentType: 'image/png',
  size: 2048,
);

class _Writer implements ClipboardImageWriter {
  @override
  Future<void> writeImage(Future<Uint8List> bytes) async {
    await bytes;
  }
}

class _Exporter implements ImageExporter {
  @override
  bool get canShare => false;

  @override
  bool get savesToLibrary => false;

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

typedef _Action =
    Future<String?> Function(
      WidgetRef ref,
      api.Attachment image,
      Future<Uint8List> Function() loadBytes,
    );

Future<void> _leaveMidLoad(WidgetTester tester, _Action action) async {
  final loaded = Completer<Uint8List>();
  final container = ProviderContainer(
    overrides: [
      clipboardImageWriterProvider.overrideWithValue(_Writer()),
      imageExporterProvider.overrideWithValue(_Exporter()),
    ],
  );
  addTearDown(container.dispose);
  late Future<String?> result;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          result = action(ref, _image, () => loaded.future);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const SizedBox.shrink(),
    ),
  );
  loaded.complete(Uint8List(4));

  expect(await result, isNull);
  expect(tester.takeException(), isNull);
  expect(container.read(toastsProvider), hasLength(1));
  await tester.pump(ToastsController.defaultDuration);
}

void main() {
  testWidgets('a copy that finishes after the viewer closed still confirms', (
    tester,
  ) async {
    await _leaveMidLoad(tester, copyImageToClipboard);
  });

  testWidgets('a save that finishes after the viewer closed still confirms', (
    tester,
  ) async {
    await _leaveMidLoad(tester, saveImageToDevice);
  });
}
