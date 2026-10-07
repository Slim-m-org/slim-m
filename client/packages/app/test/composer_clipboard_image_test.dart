// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's mobile clipboard-image bridge, proven at the platform
/// channel: nothing on this box can drive a real iOS or Android pasteboard,
/// or a real Objective-C method swizzle.
///
/// Proves the Dart-side contract only - that [hasClipboardImage] and
/// [readClipboardImage] call the right method with the right shape, that a platform failure becomes
/// [ClipboardImageReadException] rather than a silent null, and that
/// [startClipboardImagePaste] reaches its callback when the platform side
/// invokes `pastedImage` on this same channel. It does not and cannot prove
/// what `UIPasteboard`, `ClipboardManager` or `ClipboardPasteBridge.m`'s
/// swizzle actually do on a device; that needs one.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/composer_clipboard_image.dart';

const _channelName = 'top.npcserver.slimm/clipboard_image';
const _channel = MethodChannel(_channelName);

void _mock(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handler);
}

/// Simulates the platform side calling Dart, the direction
/// [startClipboardImagePaste]'s handler answers rather than [_mock]'s own
/// outgoing-call mock, which is the opposite direction.
Future<void> _deliverNativeCall(MethodCall call) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channelName,
          const StandardMethodCodec().encodeMethodCall(call),
          (_) {},
        );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => _mock(null));

  test('hasClipboardImage asks the platform for hasImage', () async {
    MethodCall? seen;
    _mock((call) async {
      seen = call;
      return true;
    });

    expect(await hasClipboardImage(), isTrue);
    expect(seen?.method, 'hasImage');
  });

  test('hasClipboardImage answers false with no platform handler', () async {
    expect(await hasClipboardImage(), isFalse);
  });

  test('readClipboardImage asks the platform for readImage and returns its '
      'bytes', () async {
    MethodCall? seen;
    _mock((call) async {
      seen = call;
      return Uint8List.fromList([1, 2, 3]);
    });

    final bytes = await readClipboardImage();
    expect(seen?.method, 'readImage');
    expect(bytes, [1, 2, 3]);
  });

  test(
    'readClipboardImage answers null for "no image", not an error',
    () async {
      _mock((call) async => null);
      expect(await readClipboardImage(), isNull);
    },
  );

  test('readClipboardImage answers null with no platform handler', () async {
    expect(await readClipboardImage(), isNull);
  });

  test('a platform read failure becomes ClipboardImageReadException carrying '
      'the platform message, not a silent null', () async {
    _mock((call) async {
      throw PlatformException(
        code: 'read_failed',
        message:
            'The app that copied this image did not allow it to be '
            'read.',
      );
    });

    await expectLater(
      readClipboardImage,
      throwsA(
        isA<ClipboardImageReadException>().having(
          (e) => e.message,
          'message',
          'The app that copied this image did not allow it to be read.',
        ),
      ),
    );
  });

  group('startClipboardImagePaste/stopClipboardImagePaste', () {
    // stop() now only tears down its own still-registered callback, so tearDown needs each test's own reference.
    late PastedImageHandler current;
    tearDown(() => stopClipboardImagePaste(current));

    test('a native pastedImage call reaches the registered callback', () async {
      Uint8List? bytes;
      String? filename;
      current = (b, f) {
        bytes = b;
        filename = f;
      };
      startClipboardImagePaste(current);

      await _deliverNativeCall(
        MethodCall('pastedImage', Uint8List.fromList([9, 9, 2])),
      );

      expect(bytes, [9, 9, 2]);
      expect(filename, 'pasted-image.png');
    });

    test('an unrelated method name is ignored, even carrying bytes', () async {
      var called = false;
      current = (_, _) => called = true;
      startClipboardImagePaste(current);

      await _deliverNativeCall(
        MethodCall('somethingElse', Uint8List.fromList([9, 9, 2])),
      );

      expect(called, isFalse);
    });

    test('a pastedImage call carrying no bytes is ignored', () async {
      var called = false;
      current = (_, _) => called = true;
      startClipboardImagePaste(current);

      await _deliverNativeCall(const MethodCall('pastedImage'));

      expect(called, isFalse);
    });

    test('stopClipboardImagePaste clears the handler', () async {
      var called = false;
      current = (_, _) => called = true;
      startClipboardImagePaste(current);
      stopClipboardImagePaste(current);

      await _deliverNativeCall(
        MethodCall('pastedImage', Uint8List.fromList([1])),
      );

      expect(called, isFalse);
    });

    test(
      "stopping with a different callback leaves the active one running",
      () async {
        var called = false;
        current = (_, _) => called = true;
        startClipboardImagePaste(current);

        stopClipboardImagePaste((_, _) {});

        await _deliverNativeCall(
          MethodCall('pastedImage', Uint8List.fromList([1])),
        );

        expect(
          called,
          isTrue,
          reason:
              'a stale caller stopping with its own, no-longer-active '
              'callback must not tear down a different one that took over',
        );
      },
    );
  });
}
