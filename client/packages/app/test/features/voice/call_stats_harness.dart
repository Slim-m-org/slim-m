// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Call stats screen over a controller driven by a [FakeSettingsSession].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/call_stats_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'voice_settings_screen_harness.dart';

List<Override> _overrides(FakeSettingsSession session) => [
  sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
  apiProvider.overrideWith((ref) {
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: voiceTokenClient(),
    );
    ref.onDispose(api.close);
    return api;
  }),
  voiceControllerProvider.overrideWith(
    (ref) => VoiceController(ref, session: session),
  ),
];

Widget callStatsScreenFor(FakeSettingsSession session) =>
    UncontrolledProviderScope(
      container: ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          ..._overrides(session),
        ],
      )..read(preferencesProvider),
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const CallStatsScreen(),
      ),
    );
