// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser watcher that hands each new `livekit_audio_*` element its gain.
@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/web_gain_web.dart';

@JS('document.createElement')
external _El _createElement(String tag);

@JS('document.body.appendChild')
external void _appendToBody(_El element);

@JS('document.querySelectorAll')
external _Els _all(String selector);

extension type _Els._(JSObject _) implements JSObject {
  external int get length;
  external _El item(int index);
}

extension type _El._(JSObject _) implements JSObject {
  external set id(String value);
  external void remove();
  external void appendChild(_El child);
}

_El _audio(String id) {
  final element = _createElement('audio')..id = id;
  return element;
}

Future<void> _mutationsDelivered() => Future<void>.delayed(Duration.zero);

void main() {
  late List<String> arrived;
  late void Function() stop;

  setUp(() {
    final stale = _all('audio');
    for (var i = stale.length - 1; i >= 0; i--) {
      stale.item(i).remove();
    }
    arrived = [];
    stop = watchWebAudioArrivals(arrived.add);
  });

  tearDown(() => stop());

  test('a newly added element is reported once, by its track id', () async {
    _appendToBody(_audio('livekit_audio_x'));
    await _mutationsDelivered();

    expect(arrived, ['x']);
  });

  test('an unrelated element is not reported', () async {
    _appendToBody(_audio('somebody_elses_audio'));
    _appendToBody(_createElement('div'));
    await _mutationsDelivered();

    expect(arrived, isEmpty);
  });

  test('an element inside a later-added container is reported', () async {
    final container = _createElement('div')..id = 'livekit_audio_container';
    container.appendChild(_audio('livekit_audio_inner'));
    _appendToBody(container);
    await _mutationsDelivered();

    expect(arrived, ['inner']);
    container.remove();
  });

  test('a removed then re-added element is reported again', () async {
    final element = _audio('livekit_audio_x');
    _appendToBody(element);
    await _mutationsDelivered();
    element.remove();
    await _mutationsDelivered();
    _appendToBody(element);
    await _mutationsDelivered();

    expect(arrived, ['x', 'x']);
  });

  test('stopping the watch disconnects it', () async {
    stop();
    _appendToBody(_audio('livekit_audio_late'));
    await _mutationsDelivered();

    expect(arrived, isEmpty);
  });
}
