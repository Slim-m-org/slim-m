// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser-only seams: window focus into the lifecycle, the tab-close
/// confirmation and a paste of several files, driven with real DOM events.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart' show DropItem;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_clipboard_image_web.dart';
import 'package:slimm_app/src/features/composer/widgets/unload_guard_web.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/browser_window_events_web.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:web/web.dart' as web;

bool _unloadPrevented() {
  final event = web.Event('beforeunload', web.EventInit(cancelable: true));
  web.window.dispatchEvent(event);
  return event.defaultPrevented;
}

web.File _file(String name) => web.File(
  [
    Uint8List.fromList([1, 2, 3]).toJS,
  ].toJS,
  name,
);

void main() {
  test('closing the tab is confirmed only while work is staged', () {
    final owner = Object();
    expect(_unloadPrevented(), isFalse);
    guardUnload(owner, active: true);
    expect(_unloadPrevented(), isTrue);
    guardUnload(owner, active: false);
    expect(_unloadPrevented(), isFalse);
  });

  test('every pasted file reaches the handler under its own name', () {
    List<DropItem>? pasted;
    void onImage(Uint8List bytes, String name) {}
    startClipboardFilePaste(onImage, (files) => pasted = files);
    addTearDown(() => stopClipboardImagePaste(onImage));

    final transfer = web.DataTransfer()
      ..items.add(_file('report.pdf'))
      ..items.add(_file('photo.png'));
    web.document.dispatchEvent(
      web.ClipboardEvent(
        'paste',
        web.ClipboardEventInit(clipboardData: transfer, cancelable: true),
      ),
    );

    return Future<void>.delayed(Duration.zero, () {
      expect(pasted!.map((f) => f.name), ['report.pdf', 'photo.png']);
    });
  });

  testWidgets('a blurred browser window is inactive until it regains focus', (
    tester,
  ) async {
    final notifier = AppLifecycleNotifier(
      mobile: false,
      windowEvents: browserWindowEvents(),
    );
    addTearDown(notifier.dispose);
    expect(notifier.state, AppLifecycleState.resumed);

    web.window.dispatchEvent(web.Event('blur'));
    await tester.pump();
    expect(notifier.state, AppLifecycleState.inactive);

    web.window.dispatchEvent(web.Event('focus'));
    await tester.pump();
    expect(notifier.state, AppLifecycleState.resumed);
  });

  test('staging an attachment arms the tab-close confirmation', () async {
    final gate = Completer<api.Attachment>();
    final controller = AttachmentStagingController(
      upload: (_, _, _) => gate.future,
    );
    expect(_unloadPrevented(), isFalse);

    unawaited(controller.stage(Uint8List.fromList([1, 2]), 'a.png'));
    expect(_unloadPrevented(), isTrue);

    controller.dispose();
    expect(_unloadPrevented(), isFalse);
  });

  test(
    'the lifecycle provider takes its window events from the browser',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final seen = <DesktopWindowEventKind>[];
      final sub = container
          .read(lifecycleWindowEventsProvider)
          .listen(seen.add);
      web.window.dispatchEvent(web.Event('blur'));
      web.window.dispatchEvent(web.Event('focus'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, [DesktopWindowEventKind.blur, DesktopWindowEventKind.focus]);
    },
  );

  testWidgets('the app lifecycle provider follows the provided window events', (
    tester,
  ) async {
    final events = StreamController<DesktopWindowEventKind>.broadcast();
    final container = ProviderContainer(
      overrides: [
        lifecycleWindowEventsProvider.overrideWithValue(events.stream),
      ],
    );
    addTearDown(() {
      container.dispose();
      unawaited(events.close());
    });
    expect(container.read(appLifecycleProvider), AppLifecycleState.resumed);

    events.add(DesktopWindowEventKind.blur);
    await tester.pump();
    expect(container.read(appLifecycleProvider), AppLifecycleState.inactive);

    events.add(DesktopWindowEventKind.focus);
    await tester.pump();
    expect(container.read(appLifecycleProvider), AppLifecycleState.resumed);
  });

  test('the window events are the desktop kinds', () async {
    final seen = <DesktopWindowEventKind>[];
    final sub = browserWindowEvents().listen(seen.add);
    web.window.dispatchEvent(web.Event('blur'));
    web.window.dispatchEvent(web.Event('focus'));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, [DesktopWindowEventKind.blur, DesktopWindowEventKind.focus]);
  });
}
