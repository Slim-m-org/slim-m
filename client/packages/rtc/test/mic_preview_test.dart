// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The preview opens one capture at a time, follows a device change, and says
/// so when the capture cannot be read.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

class _Source implements MicPreviewSource {
  final events = <String>[];
  Object? openError;
  ({double levelDb, bool voice})? level = (levelDb: -30.0, voice: true);
  Duration openDelay = Duration.zero;

  @override
  Future<void> open(String? deviceId) async {
    events.add('open:${deviceId ?? 'default'}');
    await Future<void>.delayed(openDelay);
    final error = openError;
    if (error != null) throw error;
  }

  @override
  Future<({double levelDb, bool voice})?> read() async => level;

  @override
  Future<void> close() async => events.add('close');
}

MicPreview _preview(
  _Source source, {
  int maxMisses = 3,
  Duration openTimeout = const Duration(seconds: 10),
}) =>
    MicPreview(
      source: source,
      interval: const Duration(milliseconds: 5),
      maxMisses: maxMisses,
      openTimeout: openTimeout,
    );

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('reads the level and voice state once the capture is open', () async {
    final preview = _preview(_Source());
    addTearDown(preview.dispose);

    await preview.start(null);
    await _until(() => preview.current.status == MicPreviewStatus.live);

    expect(preview.current.levelDb, -30.0);
    expect(preview.current.voice, isTrue);
  });

  test('stop closes the capture and goes idle', () async {
    final source = _Source();
    final preview = _preview(source);
    addTearDown(preview.dispose);
    await preview.start(null);

    await preview.stop();

    expect(preview.current.status, MicPreviewStatus.idle);
    expect(source.events.last, 'close');
  });

  test('switching device closes the old capture before opening the new one',
      () async {
    final source = _Source()..openDelay = const Duration(milliseconds: 20);
    final preview = _preview(source);
    addTearDown(preview.dispose);

    unawaited(preview.start('a'));
    await preview.start('b');

    expect(source.events, ['close', 'close', 'open:b']);
  });

  test('a stop during an open does not leave the capture running', () async {
    final source = _Source()..openDelay = const Duration(milliseconds: 20);
    final preview = _preview(source);
    addTearDown(preview.dispose);

    unawaited(preview.start('a'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await preview.stop();

    expect(source.events.last, 'close');
    expect(preview.current.status, MicPreviewStatus.idle);
  });

  test('a capture that cannot open is unavailable and closed', () async {
    final source = _Source()..openError = StateError('denied');
    final preview = _preview(source);
    addTearDown(preview.dispose);

    await preview.start(null);

    expect(preview.current.status, MicPreviewStatus.unavailable);
    expect(source.events.last, 'close');
  });

  test('a capture that never reports a level becomes unavailable', () async {
    final source = _Source()..level = null;
    final preview = _preview(source);
    addTearDown(preview.dispose);

    await preview.start(null);
    await _until(
      () => preview.current.status == MicPreviewStatus.unavailable,
    );

    expect(source.events.last, 'close');
  });

  test('a capture that never finishes opening becomes unavailable', () async {
    final source = _Source()..openDelay = const Duration(seconds: 5);
    final preview = _preview(
      source,
      openTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(preview.dispose);

    await preview.start(null);

    expect(preview.current.status, MicPreviewStatus.unavailable);
    expect(source.events.last, 'close');
  });

  test(
      'a stop during an open that never finishes does not hold up the next start',
      () async {
    final source = _Source()..openDelay = const Duration(hours: 1);
    final preview = _preview(source, openTimeout: const Duration(hours: 1));
    addTearDown(preview.dispose);

    unawaited(preview.start(null));
    await _until(() => source.events.contains('open:default'));
    await preview.stop();
    source.openDelay = Duration.zero;
    await preview.start('mic-2');

    expect(preview.current.status, isNot(MicPreviewStatus.unavailable));
    expect(source.events, contains('open:mic-2'));
  });
}
