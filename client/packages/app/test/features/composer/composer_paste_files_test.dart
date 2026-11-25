// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ctrl+V of files copied in Windows Explorer: they attach like a drop of
/// them, folders are refused, and other platforms never ask for a file list.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_clipboard_paste.dart';
import 'package:slimm_app/src/features/composer/widgets/staged_attachment_model.dart';

const _channel = MethodChannel('top.npcserver.slimm/clipboard_image');

void _answer(Future<Object?> Function(MethodCall) handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handler);
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late List<String> calls;
  late List<FileSource> staged;
  late List<String> images;
  late List<String?> errors;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('slimm-paste');
    calls = [];
    staged = [];
    images = [];
    errors = [];
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      dir.deleteSync(recursive: true);
    });
  });

  Future<void> ctrlV() => pasteClipboardImageFromKeystroke(
    (bytes, name) async => images.add(name),
    errors.add,
    stageFile: (file) async => staged.add(file),
  );

  test('files from the clipboard attach and nothing else is read', () async {
    final a = File('${dir.path}/a.txt')..writeAsStringSync('hello');
    final b = File('${dir.path}/b.bin')..writeAsBytesSync([1, 2, 3]);
    _answer((call) async {
      calls.add(call.method);
      return call.method == 'readFiles' ? [a.path, b.path] : null;
    });

    await ctrlV();

    expect(staged.map((f) => f.name), ['a.txt', 'b.bin']);
    expect(await staged.first.length(), 5);
    expect(calls, ['readFiles']);
    expect(images, isEmpty);
  });

  test('a folder is refused and the files beside it still attach', () async {
    final a = File('${dir.path}/a.txt')..writeAsStringSync('x');
    final folder = Directory('${dir.path}/pics')..createSync();
    _answer((call) async => [folder.path, a.path]);

    await ctrlV();

    expect(staged.map((f) => f.name), ['a.txt']);
    expect(errors.last, contains('Folders'));
  });

  test('no files on the clipboard falls through to the image route', () async {
    _answer((call) async {
      calls.add(call.method);
      return call.method == 'readFiles' ? <String>[] : false;
    });

    await ctrlV();

    expect(calls, ['readFiles', 'hasImage']);
    expect(staged, isEmpty);
  });

  test('a busy clipboard is reported rather than swallowed', () async {
    _answer((call) async {
      throw PlatformException(code: 'clipboard_busy', message: 'In use');
    });

    await ctrlV();

    expect(errors.last, 'In use');
    expect(staged, isEmpty);
  });

  test('other platforms never ask for a file list', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    _answer((call) async {
      calls.add(call.method);
      return false;
    });

    await ctrlV();

    expect(calls, ['hasImage']);
  });
}
