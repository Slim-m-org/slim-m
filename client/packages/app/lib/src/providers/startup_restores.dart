// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The preferences bootstrap restores before the first frame, and the guard
/// that keeps one of them from stranding the splash.
///
/// A preferences file that is truncated or corrupt (a power loss or a full
/// disk mid-write) makes every read of it throw. A restore that throws used to
/// reject the whole bootstrap, which nothing caught, so the app sat on
/// "Loading preferences" with nothing the person could do but delete the file
/// by hand. Each restore now falls back to its controller's default and says
/// so in the debug log.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'app_lock_preference.dart';
import '../features/messages/providers/attachment_preview_quality.dart';
import 'desktop_splash_preference.dart';
import '../features/settings/providers/display_density.dart';
import '../features/settings/providers/display_preferences.dart';
import '../features/messages/providers/image_cache_preference.dart';
import '../features/messages/providers/media_preferences.dart';
import '../features/messages/providers/message_page_size.dart';
import 'preference_controller.dart';
import 'providers.dart';
import '../features/channels/providers/rail_width_preference.dart';
import '../features/voice/providers/voice_controller.dart';
import '../features/voice/providers/voice_flags.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

/// Runs [restore], and on any failure records it and carries on: [name]'s
/// controller keeps its default, which is always a usable answer.
Future<void> restoreOrDefault(
  ProviderContainer container,
  String name,
  Future<void> restore,
) async {
  try {
    await restore;
  } catch (error, stack) {
    AppLog.warning(
      LogTag.data,
      'Could not restore the saved $name setting; using the default',
      error: error,
      stack: stack,
    );
  }
}

/// Every controller that restores itself at startup. A new preference
/// controller is added here or `startup_restore_registry_test.dart` fails.
final Map<String, RestorablePreference Function(ProviderContainer)>
restorablePreferences = {
  'theme': (c) => c.read(themeControllerProvider.notifier),
  'time format': (c) => c.read(timeFormatControllerProvider.notifier),
  'motion': (c) => c.read(motionPreferenceControllerProvider.notifier),
  'high contrast': (c) => c.read(highContrastControllerProvider.notifier),
  'image cache limit': (c) =>
      c.read(imageCacheLimitControllerProvider.notifier),
  'attachment preview quality': (c) =>
      c.read(attachmentPreviewQualityControllerProvider.notifier),
  'media auto download': (c) =>
      c.read(mediaAutoDownloadControllerProvider.notifier),
  'gif autoplay': (c) => c.read(gifAutoplayControllerProvider.notifier),
  'link previews': (c) => c.read(linkPreviewDisplayControllerProvider.notifier),
  'message page size': (c) =>
      c.read(messagePageSizeControllerProvider.notifier),
  'message density': (c) => c.read(messageDensityControllerProvider.notifier),
  'group spacing': (c) => c.read(groupSpacingControllerProvider.notifier),
  'continuation marker': (c) =>
      c.read(continuationMarkerControllerProvider.notifier),
  'ui scale': (c) => c.read(uiScaleControllerProvider.notifier),
  'app lock': (c) => c.read(appLockPreferenceProvider.notifier),
  'rail width': (c) => c.read(railWidthControllerProvider.notifier),
};

/// Re-reads the shared appearance and behaviour preferences into a container
/// built earlier, so an account shown after a switch matches what was just
/// changed in the one before it. Leaves the voice preferences alone: a call
/// may be running there.
Future<void> resyncSharedPreferences(ProviderContainer container) {
  return Future.wait([
    for (final entry in restorablePreferences.entries)
      restoreOrDefault(container, entry.key, entry.value(container).restore()),
  ]);
}

/// Re-reads the device-wide voice preferences into a container that has not
/// loaded them, unless it is in a call, where a restore would change a live one.
Future<void> resyncVoiceDevicePreferences(ProviderContainer container) async {
  final flags = container.read(voiceFlagsProvider);
  if (flags.state == VoiceSessionState.connected || flags.rejoining) return;
  final voice = container.read(voiceControllerProvider.notifier);
  await Future.wait([
    for (final entry in {
      'camera on join': voice.restoreCameraPreference(),
      'voice activity sensitivity': voice.restoreVoiceActivitySensitivity(),
      'input threshold': voice.restoreInputThreshold().then(
        (_) => voice.restoreInputThresholdAuto(),
      ),
      'even out loud sounds': voice.restoreEvenOutLoudSounds(),
      'noise suppression': voice.restoreNoiseSuppression(),
      'video quality': voice.restoreVideoQuality(),
      'push to talk': voice.restorePushToTalkPreference(),
      'audio devices': voice.restoreAudioDevicePreferences(),
    }.entries)
      restoreOrDefault(container, entry.key, entry.value),
  ]);
}

/// Restores every preference bootstrap needs, concurrently off the one cached
/// preferences future, each degrading on its own.
Future<void> restoreStartupPreferences(ProviderContainer container) {
  final voice = container.read(voiceControllerProvider.notifier);
  final restores = <String, Future<void>>{
    for (final entry in restorablePreferences.entries)
      entry.key: entry.value(container).restore(),
    'camera on join': voice.restoreCameraPreference(),
    'voice activity sensitivity': voice.restoreVoiceActivitySensitivity(),
    'input threshold': voice.restoreInputThreshold().then(
      (_) => voice.restoreInputThresholdAuto(),
    ),
    'even out loud sounds': voice.restoreEvenOutLoudSounds(),
    'noise suppression': voice.restoreNoiseSuppression(),
    'video quality': voice.restoreVideoQuality(),
    'push to talk': voice.restorePushToTalkPreference(),
    'audio devices': voice.restoreAudioDevicePreferences(),
    'participant volumes': voice.restoreParticipantVolumes(),
  };
  return Future.wait([
    for (final entry in restores.entries)
      restoreOrDefault(container, entry.key, entry.value),
  ]);
}

/// Restores the splash preference and answers its duration, or the default one
/// when the preference cannot be read.
Future<Duration> restoreSplashFloor(
  ProviderContainer container,
  Duration Function(ProviderContainer container) floorFor,
) async {
  await restoreOrDefault(
    container,
    'splash duration',
    container.read(splashDurationControllerProvider.notifier).restore(),
  );
  return floorFor(container);
}

/// Runs a bootstrap step that may fail without the app being unable to start,
/// recording the failure instead of letting it escape: whatever did start is
/// what the app opens with, and the splash is never left up for good.
Future<void> runStartupStep(
  ProviderContainer container,
  String name,
  Future<void> Function() step,
) async {
  try {
    await step();
  } catch (error, stack) {
    AppLog.warning(
      LogTag.data,
      'Startup step "$name" failed; opening the app anyway',
      error: error,
      stack: stack,
    );
  }
}
