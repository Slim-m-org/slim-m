// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

const _channel = MethodChannel('FlutterWebRTC.Method');

/// Records plugin calls; [resetSupported] false mimics an unpatched plugin.
List<String> _mockPlugin({
  required bool resetSupported,
  List<Map<String, Object>> extra = const [],
  List<Object?>? requestedTypes,
}) {
  final calls = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_channel, (call) async {
    if (call.method != 'initialize') calls.add(call.method);
    switch (call.method) {
      case 'resetDesktopSources':
        if (!resetSupported) throw MissingPluginException();
        return null;
      case 'getDesktopSources':
        final args = call.arguments as Map<Object?, Object?>;
        requestedTypes?.addAll(args['types'] as List<Object?>);
        return {
          'sources': [
            ...extra,
            {
              'id': '0',
              'name': 'Screen 1',
              'type': 'screen',
              'thumbnailSize': {'width': 0, 'height': 0},
            },
          ],
        };
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('on linux every share drops the cached portal session first', () async {
    final calls = _mockPlugin(resetSupported: true);
    const sources = WebrtcDesktopSources(isLinux: true);

    await sources.list();
    await sources.list();

    expect(calls, [
      'resetDesktopSources',
      'getDesktopSources',
      'resetDesktopSources',
      'getDesktopSources',
    ]);
  });

  test('a plugin without the reset method still lists sources', () async {
    final calls = _mockPlugin(resetSupported: false);

    final listed = await const WebrtcDesktopSources(isLinux: true).list();

    expect(listed.single.id, '0');
    expect(calls, ['resetDesktopSources', 'getDesktopSources']);
  });

  test('other desktops never touch the portal session', () async {
    final calls = _mockPlugin(resetSupported: true);

    await const WebrtcDesktopSources(isLinux: false).list();

    expect(calls, ['getDesktopSources']);
  });

  Map<String, Object> window(String id, String name) => {
        'id': id,
        'name': name,
        'type': 'window',
        'thumbnailSize': {'width': 0, 'height': 0},
      };

  test('windows and macos list windows after the screens', () async {
    final types = <Object?>[];
    _mockPlugin(
      resetSupported: true,
      requestedTypes: types,
      extra: [window('w1', 'Notepad'), window('w2', '  ')],
    );

    final listed = await const WebrtcDesktopSources(isLinux: false).list();

    expect(types, ['screen', 'window']);
    expect([for (final s in listed) s.id], ['0', 'w1']);
    expect(listed.last.isWindow, isTrue);
    expect(listed.first.isWindow, isFalse);
  });

  test('linux never asks for windows, which crashes there', () async {
    final types = <Object?>[];
    _mockPlugin(resetSupported: true, requestedTypes: types);

    await const WebrtcDesktopSources(isLinux: true).list();

    expect(types, ['screen']);
  });
}
