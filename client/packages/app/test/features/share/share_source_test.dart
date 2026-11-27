// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where shares come from on each platform, and what the iOS extension's batch looks like to Dart.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/features/share/providers/share_source.dart';

const _channel = MethodChannel('top.npcserver.slimm/share_intake');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  group('which platforms have a source', () {
    test('both phones listen to the share sheet', () {
      expect(
        shareSourceFor(isAndroid: true, isIOS: false),
        isA<ChannelShareSource>(),
      );
      expect(
        shareSourceFor(isAndroid: false, isIOS: true),
        isA<ChannelShareSource>(),
      );
    });

    test('every other platform has none', () {
      expect(
        shareSourceFor(isAndroid: false, isIOS: false),
        isA<NoShareSource>(),
      );
    });
  });

  group('taking an iOS share', () {
    void answerWith(Object? Function(MethodCall call) answer) {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => answer(call),
      );
    }

    test(
      'reads the files the extension copied and the link it found',
      () async {
        answerWith(
          (_) => {
            'files': [
              {
                'path':
                    '/var/mobile/Library/Caches/shared_intake/1-a/0/IMG_1.heic',
                'name': 'IMG_1.heic',
                'mimeType': 'image/heic',
                'length': 5120,
              },
              {
                'path':
                    '/var/mobile/Library/Caches/shared_intake/1-a/1/notes.pdf',
                'name': 'notes.pdf',
                'mimeType': null,
                'length': 99,
              },
            ],
            'text': 'https://example.com/page',
            'unreadable': 0,
            'tooLarge': 1,
          },
        );

        final share = await ChannelShareSource().take();

        expect(share!.files.map((f) => f.name), ['IMG_1.heic', 'notes.pdf']);
        expect(share.files.first.isImage, isTrue);
        expect(share.files.last.mimeType, isNull);
        expect(share.files.first.path, endsWith('/0/IMG_1.heic'));
        expect(share.text, 'https://example.com/page');
        expect(share.tooLarge, 1);
      },
    );

    test('a null text from the extension is no text', () async {
      answerWith(
        (_) => {
          'files': [
            {'path': '/c/0/a.png', 'name': 'a.png', 'length': 1},
          ],
          'text': null,
          'unreadable': 0,
          'tooLarge': 0,
        },
      );

      final share = await ChannelShareSource().take();

      expect(share!.hasText, isFalse);
      expect(share.hasFiles, isTrue);
    });

    test('nothing waiting opens no picker', () async {
      answerWith((_) => null);

      expect(await ChannelShareSource().take(), isNull);
    });

    test('a native failure is a missing share, not a crash', () async {
      answerWith((_) => throw PlatformException(code: 'copy_failed'));

      expect(await ChannelShareSource().take(), isNull);
    });

    test(
      'asks the native side for the share by the name Swift answers to',
      () async {
        final asked = <String>[];
        answerWith((call) {
          asked.add(call.method);
          return null;
        });

        await ChannelShareSource().take();

        expect(asked, ['take']);
      },
    );
  });

  test(
    'the app coming to the front with a share waiting announces it',
    () async {
      final source = ChannelShareSource();
      final arrived = Completer<void>();
      final sub = source.arrivals.listen((_) => arrived.complete());
      addTearDown(sub.cancel);

      await messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('arrived'),
        ),
        (_) {},
      );

      await arrived.future.timeout(const Duration(seconds: 1));
    },
  );

  test('the extension opening the app is not mistaken for another link', () {
    final opener = Uri.parse('slimm-share://intake');

    expect(inviteFromDeepLink(opener, signedIn: false), isNull);
    expect(
      messageFromDeepLink(opener, signedInTo: Uri.parse('https://x.y')),
      isNull,
    );
  });
}
