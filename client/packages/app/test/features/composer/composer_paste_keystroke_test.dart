// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ctrl+V attaching an image on the platforms with no event-driven paste
/// route of their own, which as of this change means Linux desktop.
///
/// The property worth protecting here is not that an image attaches; it is
/// that **plain text paste is untouched**. Flutter's own text editing owns
/// Ctrl+V, and this only ever runs alongside it, so the tests below assert
/// on what the keystroke does *not* do as much as on what it does.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_clipboard_paste.dart';

const _channel = MethodChannel('top.npcserver.slimm/clipboard_image');

/// Bytes of a one-pixel PNG; only the signature is ever asserted on.
final _png = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
]);

void _answer({required bool hasImage, Uint8List? image, String? readError}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        switch (call.method) {
          case 'hasImage':
            return hasImage;
          case 'readImage':
            if (readError != null) {
              throw PlatformException(code: 'read_failed', message: readError);
            }
            return image;
          default:
            return null;
        }
      });
}

/// Presses [keys] in order, releases them in reverse, and reports what
/// [isClipboardPasteChord] answered for each event **as it was dispatched**.
///
/// Evaluated inside the handler rather than afterwards on a captured event,
/// because the predicate reads the held modifiers off [HardwareKeyboard]
/// rather than off the event, so asking once the keys are released always
/// answers false regardless of what was pressed.
Future<List<bool>> _chordAnswers(
  WidgetTester tester,
  List<LogicalKeyboardKey> keys,
) async {
  final answers = <bool>[];
  bool handler(KeyEvent event) {
    answers.add(isClipboardPasteChord(event));
    return false;
  }

  HardwareKeyboard.instance.addHandler(handler);
  for (final key in keys) {
    await tester.sendKeyDownEvent(key);
  }
  for (final key in keys.reversed) {
    await tester.sendKeyUpEvent(key);
  }
  HardwareKeyboard.instance.removeHandler(handler);
  return answers;
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Ctrl+V is the paste chord, and exactly once per press', (
    tester,
  ) async {
    final answers = await _chordAnswers(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyV,
    ]);

    expect(
      answers.where((yes) => yes).length,
      1,
      reason: 'the two key-ups must not each attach another copy',
    );
  });

  testWidgets('holding Ctrl+V down attaches once, not once per repeat', (
    tester,
  ) async {
    final answers = <bool>[];
    bool handler(KeyEvent event) {
      answers.add(isClipboardPasteChord(event));
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    HardwareKeyboard.instance.removeHandler(handler);

    expect(
      answers.where((yes) => yes).length,
      1,
      reason: 'two repeats must not stage two more copies of the same image',
    );
  });

  testWidgets('a bare V, with no modifier, is not', (tester) async {
    final answers = await _chordAnswers(tester, [LogicalKeyboardKey.keyV]);
    expect(answers, everyElement(isFalse));
  });

  testWidgets('Ctrl with any other letter is not', (tester) async {
    final answers = await _chordAnswers(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyC,
    ]);
    expect(answers, everyElement(isFalse));
  });

  test('an image on the clipboard is staged', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    _answer(hasImage: true, image: _png);

    final staged = <String>[];
    String? error;
    await pasteClipboardImageFromKeystroke(
      (bytes, filename) async => staged.add(filename),
      (message) => error = message,
    );

    expect(staged, ['pasted-image.png']);
    expect(error, isNull);
  });

  test(
    'a clipboard holding no image stages nothing and clears nothing',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      _answer(hasImage: false);

      final staged = <String>[];
      var setErrorCalls = 0;
      await pasteClipboardImageFromKeystroke(
        (bytes, filename) async => staged.add(filename),
        (message) => setErrorCalls++,
      );

      expect(staged, isEmpty);
      expect(
        setErrorCalls,
        0,
        reason: 'a plain text paste must not clear a failure nobody has read',
      );
    },
  );

  test(
    'iOS never polls, because reading there prompts on every call',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var asked = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            asked++;
            return call.method == 'hasImage' ? true : _png;
          });

      final staged = <String>[];
      await pasteClipboardImageFromKeystroke(
        (bytes, filename) async => staged.add(filename),
        (_) {},
      );

      expect(
        asked,
        0,
        reason: 'iOS has the edit-menu route and must not prompt',
      );
      expect(staged, isEmpty);
    },
  );

  test('a read failure surfaces rather than being swallowed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    _answer(
      hasImage: true,
      readError: 'The clipboard image could not be read.',
    );

    String? error;
    await pasteClipboardImageFromKeystroke(
      (bytes, filename) async {},
      (message) => error = message,
    );

    expect(error, 'The clipboard image could not be read.');
  });
}
