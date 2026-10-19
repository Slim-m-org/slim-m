// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/messages/providers/image_cache_preference.dart';
import 'package:slimm_design_system/design_system.dart' show AppDensity;
import 'package:slimm_app/src/features/settings/providers/display_density.dart';
import 'package:slimm_app/src/providers/space_scoped_preferences.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

ProviderContainer _containerFor(String origin) {
  final slot = AccountSlot(
    account: Account.forServer(Uri.parse(origin)),
    chooseServer: (slot, server) => throw StateError('unused'),
  );
  return ProviderContainer(
    overrides: [accountSlotProvider.overrideWithValue(slot)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two Spaces hold different values and each shows its own', () async {
    SharedPreferences.setMockInitialValues({});
    final a = _containerFor(_a);
    final b = _containerFor(_b);
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await a
        .read(messageDensityControllerProvider.notifier)
        .select(AppDensity.compact);
    await b
        .read(messageDensityControllerProvider.notifier)
        .select(AppDensity.spacious);

    final freshA = _containerFor(_a);
    final freshB = _containerFor(_b);
    addTearDown(freshA.dispose);
    addTearDown(freshB.dispose);
    await freshA.read(messageDensityControllerProvider.notifier).restore();
    await freshB.read(messageDensityControllerProvider.notifier).restore();
    expect(freshA.read(messageDensityControllerProvider), AppDensity.compact);
    expect(freshB.read(messageDensityControllerProvider), AppDensity.spacious);
  });

  test('values saved before the change become every Space\'s values', () async {
    SharedPreferences.setMockInitialValues({
      messageDensityKey: AppDensity.compact.name,
    });
    for (final origin in [_a, _b]) {
      final c = _containerFor(origin);
      addTearDown(c.dispose);
      await c.read(messageDensityControllerProvider.notifier).restore();
      expect(c.read(messageDensityControllerProvider), AppDensity.compact);
    }
  });

  test('a change in one Space leaves the others on the old value', () async {
    SharedPreferences.setMockInitialValues({
      messageDensityKey: AppDensity.compact.name,
    });
    final a = _containerFor(_a);
    addTearDown(a.dispose);
    await a
        .read(messageDensityControllerProvider.notifier)
        .select(AppDensity.spacious);
    final b = _containerFor(_b);
    addTearDown(b.dispose);
    await b.read(messageDensityControllerProvider.notifier).restore();
    expect(b.read(messageDensityControllerProvider), AppDensity.compact);
  });

  test('device-wide settings are one value for every Space', () async {
    SharedPreferences.setMockInitialValues({});
    final a = _containerFor(_a);
    final b = _containerFor(_b);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.read(imageCacheLimitControllerProvider.notifier).select(200);
    await b.read(imageCacheLimitControllerProvider.notifier).restore();
    expect(b.read(imageCacheLimitControllerProvider), 200);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(imageCacheLimitKey), isTrue);
    expect(
      prefs.getKeys().where((k) => k.contains(imageCacheLimitKey)),
      hasLength(1),
    );
  });

  test('every slimm key in the app is classified one way or the other', () {
    final key = RegExp(r"'(slimm\.[a-z_]+\.[a-z_.]+)'");
    final unclassified = <String>{};
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      for (final m in key.allMatches(file.readAsStringSync())) {
        final k = m.group(1)!;
        if (!spaceScopedKeys.contains(k) && !_deviceKeys.contains(k)) {
          unclassified.add(k);
        }
      }
    }
    expect(unclassified, isEmpty, reason: 'classify in decision 0070');
  });
}

/// The device-wide counterpart of [spaceScopedKeys]; see decision 0070.
const _deviceKeys = <String>{
  'slimm.appearance.high_contrast',
  'slimm.appearance.motion',
  'slimm.appearance.ui_scale',
  'slimm.canvas.self_bubble.hidden',
  'slimm.canvas.snap_to_grid',
  'slimm.database.key',
  'slimm.desktop.window_geometry',
  'slimm.first_run.done.',
  'slimm.first_run.voice_hint.',
  'slimm.layout.rail_width',
  'slimm.performance.desktop_splash_duration',
  'slimm.performance.desktop_splash_enabled',
  'slimm.performance.image_cache_mb',
  'slimm.performance.message_page_size',
  'slimm.performance.preview_quality',
  'slimm.rail.collapsed_categories',
  'slimm.security.app_lock',
  'slimm.spotify.account',
  'slimm.spotify.pending',
  'slimm.spotify.tokens',
  'slimm.update.dismissed_version',
  'slimm.updates.automatic',
  'slimm.voice.activity_sensitivity',
  'slimm.voice.audio_input_device_id',
  'slimm.voice.audio_output_device_id',
  'slimm.voice.camera_on_join',
  'slimm.voice.camera_quality',
  'slimm.voice.even_out_loud',
  'slimm.voice.hidden_cameras',
  'slimm.voice.input_threshold_auto',
  'slimm.voice.input_threshold_db',
  'slimm.voice.noise_suppression',
  'slimm.voice.participant_screen_volumes',
  'slimm.voice.participant_volumes',
  'slimm.voice.pause_video_when_unfocused',
  'slimm.voice.push_to_talk_enabled',
  'slimm.voice.push_to_talk_key_id',
  'slimm.voice.receive_video_quality',
  'slimm.voice.screen_share_include_audio',
  'slimm.voice.screen_share_quality',
  'slimm.voice.shortcut_overrides',
  'slimm.whats_new.last_seen_version',
};
