// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Android save step hands the file path to the native channel and never its bytes.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/downloads/phone_file_saver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('top.npcserver.slimm/file_export');
  final calls = <MethodCall>[];

  void answer(Object? result) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return result;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  test('the file goes over by path, and a saved answer is true', () async {
    answer(true);

    final saved = await documentFileSaver(File('/cache/a.bin'), 'a.bin');

    expect(saved, isTrue);
    expect(calls.single.method, 'saveCopy');
    expect(calls.single.arguments, {
      'path': '/cache/a.bin',
      'fileName': 'a.bin',
    });
  });

  test('a dismissed dialog is not a save', () async {
    answer(false);

    expect(await documentFileSaver(File('/cache/a.bin'), 'a.bin'), isFalse);
  });
}
