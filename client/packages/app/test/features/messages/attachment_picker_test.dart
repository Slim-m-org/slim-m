// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer and avatar attach actions' shared picker, proven at the
/// `file_picker` platform interface: nothing on this box can drive a real OS
/// picker, and `attachment_picker.dart`'s whole reason to exist is that the
/// two [AttachmentSource] routes must ask the plugin for different things.
///
/// Proves: [AttachmentSource.photoLibrary] requests `FileType.image`, which
/// is what selects the Photos-backed `PHPickerViewController` on iOS, and
/// [AttachmentSource.fileBrowser] requests the plugin's default (no `type:`
/// at all), which is what selects `UIDocumentPickerViewController` there
/// instead. Does not prove either OS actually shows a different picker for
/// that request, or that a file picked outside the camera roll decodes as a
/// usable image; neither is checkable without a phone.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart' show FocusNode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_picker.dart';
import 'package:slimm_app/src/features/messages/widgets/system_photo_picker.dart';

import '../composer/composer_harness.dart'
    show FakePlatformFile, pickedFile, usePicker;

/// A host with only `file_picker`, which is every platform but Android.
ProviderContainer _withoutSystemPicker() => ProviderContainer(
  overrides: [systemPhotoPickerAvailableProvider.overrideWithValue(false)],
);

void main() {
  test('the photo library route asks the plugin for FileType.image', () async {
    // A null file is the shape a cancelled pick returns.
    final picker = usePicker(null);

    final container = _withoutSystemPicker();
    addTearDown(container.dispose);
    final picked = await container.read(
      attachmentPickerProvider(AttachmentSource.photoLibrary),
    )();

    expect(picked, isNull);
    expect(picker.calls, 1);
    expect(picker.lastType, FileType.image);
  });

  test('the media library route asks the plugin for FileType.media', () async {
    final picker = usePicker(null);

    final container = _withoutSystemPicker();
    addTearDown(container.dispose);
    await container.read(
      attachmentPickerProvider(AttachmentSource.mediaLibrary),
    )();

    expect(
      picker.lastType,
      FileType.media,
      reason: 'a camera roll video must be reachable from the composer',
    );
  });

  test(
    'the file browser route asks the plugin for the default FileType.any',
    () async {
      final picker = usePicker(null);

      final container = _withoutSystemPicker();
      addTearDown(container.dispose);
      final picked = await container.read(
        attachmentPickerProvider(AttachmentSource.fileBrowser),
      )();

      expect(picked, isNull);
      expect(picker.calls, 1);
      expect(
        picker.lastType,
        FileType.any,
        reason: 'the document browser opens with no type filter at all',
      );
    },
  );

  test('the still image route filters the browser to still pictures', () async {
    final picker = usePicker(null);
    final container = _withoutSystemPicker();
    addTearDown(container.dispose);
    await container.read(
      attachmentPickerProvider(AttachmentSource.stillImageFiles),
    )();
    expect(picker.lastType, FileType.custom);
    expect(picker.lastAllowedExtensions, ['png', 'jpg', 'jpeg', 'webp']);
  });

  group('on Android', () {
    late List<({bool videos, bool multiple})> asked;
    late List<PlatformFile> chosen;

    ProviderContainer open() {
      asked = [];
      chosen = [pickedFile(), pickedFile()];
      final container = ProviderContainer(
        overrides: [
          systemPhotoPickerAvailableProvider.overrideWithValue(true),
          systemPhotoPickerProvider.overrideWithValue(({
            required bool videos,
            required bool multiple,
          }) async {
            asked.add((videos: videos, multiple: multiple));
            return chosen;
          }),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'both photo sources open the system photo picker, not file_picker',
      () async {
        final picker = usePicker(null);
        final container = open();
        await container.read(
          attachmentPickerProvider(AttachmentSource.photoLibrary),
        )();
        await container.read(
          attachmentPickerProvider(AttachmentSource.mediaLibrary),
        )();
        expect(picker.calls, 0);
        expect(asked, [
          (videos: false, multiple: false),
          (videos: true, multiple: false),
        ]);
      },
    );

    test('the composer batch picker keeps multi-select with videos', () async {
      usePicker(null);
      final container = open();
      final files = await container.read(
        attachmentBatchPickerProvider(AttachmentSource.mediaLibrary),
      )();
      expect(files, hasLength(2));
      expect(asked, [(videos: true, multiple: true)]);
    });

    test('the file browser still opens the documents browser', () async {
      final picker = usePicker(null);
      final container = open();
      await container.read(
        attachmentBatchPickerProvider(AttachmentSource.fileBrowser),
      )();
      expect(picker.calls, 1);
      expect(picker.lastType, FileType.any);
      expect(asked, isEmpty);
    });
  });

  test('iOS keeps routing photos through file_picker', () async {
    final picker = usePicker(null);
    final container = ProviderContainer(
      overrides: [
        systemPhotoPickerAvailableProvider.overrideWithValue(false),
        systemPhotoPickerProvider.overrideWithValue(
          ({required bool videos, required bool multiple}) =>
              fail('the Android picker must not open on iOS'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(
      attachmentBatchPickerProvider(AttachmentSource.mediaLibrary),
    )();
    expect(picker.lastType, FileType.media);
  });

  test('a batch pick stages every chosen file in order', () async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final staged = <String>[];
    await runAttachmentPick(
      pick: () async => [
        FakePlatformFile('a.png', Uint8List(1)),
        FakePlatformFile('b.png', Uint8List(1)),
      ],
      focus: focus,
      isMounted: () => true,
      onPickerFailed: () => fail('the pick succeeded'),
      stage: (file) async => staged.add(file.name),
    );
    expect(staged, ['a.png', 'b.png']);
  });
}
