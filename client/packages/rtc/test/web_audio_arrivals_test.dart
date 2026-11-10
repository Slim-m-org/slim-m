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
  external set srcObject(JSObject? value);
  external bool get muted;
  external void remove();
  external void appendChild(_El child);
}

_El _audio(String id) {
  final element = _createElement('audio')..id = id;
  return element;
}

@JS('AudioContext')
extension type _Context._(JSObject _) implements JSObject {
  external _Context();
  external _Destination createMediaStreamDestination();
}

extension type _Destination._(JSObject _) implements JSObject {
  external JSObject get stream;
}

/// An element with a real stream behind it, as a gain graph needs.
_El _playingAudio(String id) =>
    _audio(id)..srcObject = _Context().createMediaStreamDestination().stream;

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

  test('a removed element has its gain graph released', () async {
    final element = _playingAudio('livekit_audio_x');
    _appendToBody(element);
    await _mutationsDelivered();
    expect(applyWebGain('x', 1.5), isNull);
    expect(element.muted, isTrue);

    element.remove();
    await _mutationsDelivered();

    expect(element.muted, isFalse);
  });

  test('a graph on an element that stays is not released by others leaving',
      () async {
    final kept = _playingAudio('livekit_audio_kept');
    final other = _playingAudio('livekit_audio_other');
    _appendToBody(kept);
    _appendToBody(other);
    await _mutationsDelivered();
    expect(applyWebGain('kept', 1.5), isNull);

    other.remove();
    await _mutationsDelivered();

    expect(kept.muted, isTrue);
  });

  test('stopping the watch releases the graphs still in place', () async {
    final element = _playingAudio('livekit_audio_x');
    _appendToBody(element);
    await _mutationsDelivered();
    expect(applyWebGain('x', 1.5), isNull);

    stop();

    expect(element.muted, isFalse);
  });
}
