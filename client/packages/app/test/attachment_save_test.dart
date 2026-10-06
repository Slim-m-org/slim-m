// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `saveAttachment` fetches through the same cached, authenticated path an
/// inline image already uses, then hands the bytes to `file_picker`'s own
/// cross-platform save flow. No platform channel involved: the picker's
/// static `saveFile` delegates to `FilePickerPlatform.instance`, faked here
/// the same way `composer_harness.dart`'s `FakePicker` fakes `pickFiles`.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/attachment_bytes.dart';
import 'package:slimm_app/src/widgets/attachment_save.dart';

const _attachment = api.Attachment(
  id: 'p1',
  filename: 'report.pdf',
  contentType: 'application/pdf',
  size: 1800000,
);

/// Extends (never implements) [FilePickerPlatform], the same token check
/// `composer_harness.dart`'s own fake satisfies.
class _FakeSaver extends FilePickerPlatform {
  _FakeSaver({this.failure});

  final Object? failure;

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
    if (failure != null) throw failure!;
    savedFileName = fileName;
    savedBytes = bytes;
    return Uri.file('/home/user/Downloads/$fileName');
  }
}

_FakeSaver _useSaver({Object? failure}) {
  final previous = FilePickerPlatform.instance;
  final saver = _FakeSaver(failure: failure);
  FilePickerPlatform.instance = saver;
  addTearDown(() => FilePickerPlatform.instance = previous);
  return saver;
}

/// A real [WidgetRef], the type [saveAttachment] takes - `saveAttachment`
/// runs from a widget's own state, never from a plain [ProviderContainer]
/// callback, so the test gets one the same way: mount a [Consumer] and
/// capture it.
Future<WidgetRef> _ref(WidgetTester tester, List<Override> overrides) async {
  late final WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: Consumer(
        builder: (context, ref, _) {
          captured = ref;
          return const SizedBox();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets(
    'fetches the attachment through the cached authenticated path and hands '
    'the exact bytes to the platform save flow',
    (tester) async {
      final saver = _useSaver();
      final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
      final ref = await _ref(tester, [
        attachmentBytesProvider(_attachment.id).overrideWith((ref) async {
          return bytes;
        }),
      ]);

      final failure = await saveAttachment(ref, _attachment);

      expect(failure, isNull);
      expect(saver.savedFileName, _attachment.filename);
      expect(saver.savedBytes, bytes);
    },
  );

  testWidgets('a fetch failure surfaces as a sentence, not an exception', (
    tester,
  ) async {
    _useSaver();
    final ref = await _ref(tester, [
      attachmentBytesProvider(_attachment.id).overrideWith((ref) async {
        throw const api.ForbiddenException('not in this channel');
      }),
    ]);

    final failure = await saveAttachment(ref, _attachment);

    expect(
      failure,
      'Could not save ${_attachment.filename}: you are not allowed to do that.',
    );
  });

  testWidgets(
    'the platform picker itself failing (no portal, refused permission) is '
    'not an ApiException, and still surfaces as a sentence',
    (tester) async {
      _useSaver(failure: Exception('no portal available'));
      final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
      final ref = await _ref(tester, [
        attachmentBytesProvider(_attachment.id).overrideWith((ref) async {
          return bytes;
        }),
      ]);

      final failure = await saveAttachment(ref, _attachment);

      expect(failure, 'Could not save ${_attachment.filename}.');
    },
  );
}
