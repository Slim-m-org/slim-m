// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A 200% OS text-scale pass over the main surfaces.
///
/// `ui_snapshot_test.dart`'s matrix renders every shipped resolution at the
/// OS default text scale; `design_system`'s `surfaces_test.dart` exercises
/// 2x scale on one isolated row component. Neither renders a real SCREEN at
/// a scale a phone or desktop user actually ships with (200% is a normal
/// accessibility setting, not an extreme one), which is where a fixed-height
/// row, a single-line label that never wraps, or a button sized to its text
/// at 100% first breaks. This reuses the same `renderSurface` harness -
/// `expectSettled`, the overflow assertion, all of it - with
/// `TextScaler.linear(2.0)` layered over a phone and a desktop viewport per
/// surface.
///
/// Theme does not affect text metrics, only color, so this runs one theme
/// rather than doubling every case the way the main matrix's dark/light
/// loop does.
library;

import 'package:flutter/widgets.dart' show TextScaler;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';

import 'ui_snapshot_support.dart';
import 'voice_snapshot_fixtures.dart'
    show SnapshotVoiceController, connectingState, dmChannelId;

const _scale = TextScaler.linear(2.0);

/// Routes with no fixture state to override: the plain shell, standalone
/// screens, and every admin pane except the two called out below.
const _plainSurfaces = <String, String>{
  'channel': '/channels/c-general',
  'no-channel-selected': '/channels',
  'channel-offline-empty': '/channels/c-empty',
  'dm-normal-transcript': '/channels/c-dm-ada',
  'onboarding': '/join',
  'sign-in': '/sign-in',
  'settings': '/settings',
  'admin-roles': '/settings/roles',
  'admin-invites': '/settings/invites',
  'admin-overwrites': '/settings/permissions',
  'admin-emoji': '/settings/emoji',
  'admin-removed-members': '/settings/removed-members',
  'admin-analytics': '/settings/analytics',
  'debug-log': '/settings/debug-log',
  'thread': '/thread/c-thread',
  'dm': '/channels/$dmChannelId',
};

/// `ReportCard`'s own nested resolve needs `renderSurface`'s
/// `settleNestedResolve` pump, or `expectSettled` catches it as a mid-flight
/// capture - see `ui_snapshot_test.dart`'s own `_nestedResolveSurfaces`.
const _nestedResolveSurfaces = {'admin-reports', 'space-settings'};

List<Override> _noOverrides() => const [];

List<Override> _voiceConnectingOverrides() => [
  voiceControllerProvider.overrideWith(
    (ref) => SnapshotVoiceController(ref, connectingState),
  ),
];

/// Routes that need a fixture override to reach the state worth checking.
const _overrideSurfaces =
    <String, ({String route, List<Override> Function() overrides})>{
      'admin-reports': (route: '/settings/reports', overrides: _noOverrides),
      'space-settings': (route: '/settings/space', overrides: _noOverrides),
      // Pinned to the connecting state, same as the main matrix's own 'voice'.
      'voice': (
        route: '/channels/c-main',
        overrides: _voiceConnectingOverrides,
      ),
    };

void main() {
  setUpAll(loadRealFonts);

  for (final surface in _plainSurfaces.entries) {
    for (final viewportName in phoneAndDesktop) {
      testWidgets(
        '${surface.key} at $viewportName (200% text scale) fits its viewport',
        (tester) async {
          await renderSurface(
            tester,
            surface.value,
            viewportName,
            'light',
            '${surface.key}-$viewportName-200pct',
            textScaler: _scale,
          );
        },
      );
    }
  }

  for (final surface in _overrideSurfaces.entries) {
    for (final viewportName in phoneAndDesktop) {
      testWidgets(
        '${surface.key} at $viewportName (200% text scale) fits its viewport',
        (tester) async {
          await renderSurface(
            tester,
            surface.value.route,
            viewportName,
            'light',
            '${surface.key}-$viewportName-200pct',
            overrides: surface.value.overrides(),
            settleNestedResolve: _nestedResolveSurfaces.contains(surface.key),
            textScaler: _scale,
          );
        },
      );
    }
  }
}
