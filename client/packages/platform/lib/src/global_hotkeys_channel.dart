// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Windows global hotkeys through the runner's low-level keyboard hook.
///
/// The hook only observes keys, so a game still receives them. The runner
/// calls `event` for each press and release and `lost` if it stops capturing.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'global_hotkeys.dart';
import 'global_hotkeys_keys.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const globalHotkeysChannelName = 'slimm/global_hotkeys';

const hookAvailableMessage = 'Works when slim-m is in the background.';
const hookFailedMessage =
    'Background capture could not start, so this works only while slim-m is focused.';
const unmappedKeyMessage =
    'This key cannot be captured in the background, so it works only while slim-m is focused.';

/// The native `bind` argument for [bindings], or null when a key has no code.
List<Map<String, Object>>? hookBindingsFor(
  List<GlobalHotkeyBinding> bindings,
) {
  final out = <Map<String, Object>>[];
  for (final binding in bindings) {
    final vk = windowsVirtualKeyFor(binding.chord.key);
    if (vk == null) return null;
    out.add({
      'id': binding.id.name,
      'vk': vk,
      'ctrl': binding.chord.ctrl,
      'alt': binding.chord.alt,
      'shift': binding.chord.shift,
      'meta': binding.chord.meta,
    });
  }
  return out;
}

/// The event a native call describes, or null when it is not one.
GlobalHotkeyEvent? hookEventFromCall(MethodCall call) {
  if (call.method == 'lost') return const GlobalHotkeyEvent.lost();
  if (call.method != 'event' || call.arguments is! Map) return null;
  final args = call.arguments as Map;
  final pressed = args['pressed'];
  if (pressed is! bool) return null;
  for (final id in GlobalHotkeyId.values) {
    if (id.name == args['id']) {
      return GlobalHotkeyEvent(
        id,
        pressed ? GlobalHotkeyPhase.pressed : GlobalHotkeyPhase.released,
      );
    }
  }
  return null;
}

class ChannelGlobalHotkeySource implements GlobalHotkeySource {
  ChannelGlobalHotkeySource({
    MethodChannel channel = const MethodChannel(globalHotkeysChannelName),
  }) : _channel = channel {
    _channel.setMethodCallHandler((call) async {
      final event = hookEventFromCall(call);
      if (event != null) _events.add(event);
    });
  }

  final MethodChannel _channel;
  final _events = StreamController<GlobalHotkeyEvent>.broadcast();

  @override
  Stream<GlobalHotkeyEvent> get events => _events.stream;

  @override
  Future<GlobalHotkeyAvailability> probe() async =>
      const GlobalHotkeyAvailability.available(hookAvailableMessage);

  @override
  Future<GlobalHotkeyAvailability> bind(
    List<GlobalHotkeyBinding> bindings,
  ) async {
    final encoded = hookBindingsFor(bindings);
    if (encoded == null) {
      return const GlobalHotkeyAvailability.unavailable(unmappedKeyMessage);
    }
    try {
      final ok = await _channel.invokeMethod<bool>('bind', encoded);
      return ok == true
          ? const GlobalHotkeyAvailability.available(hookAvailableMessage)
          : const GlobalHotkeyAvailability.unavailable(hookFailedMessage);
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(LogTag.platform, 'probe failed, ignored', error, stack);
      return const GlobalHotkeyAvailability.unavailable(hookFailedMessage);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.platform, 'probe failed, ignored', error, stack);
      return const GlobalHotkeyAvailability.unavailable(hookFailedMessage);
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('bind', <Object>[]);
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.platform,
          'Best effort: the runner also unhooks when its window is destroyed',
          error,
          stack);
    }
    await _events.close();
  }
}
