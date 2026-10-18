// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin screens `ui_snapshot_test.dart`'s own `_surfaces` map never
/// carried at all (`admin-analytics`, `admin-removed-members`, `debug-log`),
/// plus the permission-gated shapes
/// of `SpaceSettingsSection` nothing renders for a caller holding fewer than
/// every bit.
///
/// Split out rather than added to `ui_snapshot_test.dart`, which was already
/// past this repo's line budget; see that file's own surface tables for the
/// shared shape this one repeats. `renderSurface`, the viewport constants and
/// the fixture container all come from `ui_snapshot_support.dart`, so a
/// surface here renders exactly the way the rest of the matrix does.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart'
    show myPermissionsProvider;
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;
import 'package:slimm_app/src/diagnostics/debug_log.dart';

import 'ui_snapshot_support.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

/// The zero-override admin routes: reached today only by a direct
/// navigation, since nothing in the app itself deep-links these, and absent
/// from the surfaces harness entirely before this file. Each renders the
/// fixture's default answer for its own reads.
const _surfaces = <String, ({String route, List<String> viewports})>{
  // No entries yet this session is the honest default for a fresh render.
  'debug-log': (
    route: '/settings/debug-log',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  // fixtureResponse answers '/members/removed' with two real removals now.
  'admin-removed-members': (
    route: '/settings/removed-members',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  // fixtureResponse answers '/space/analytics' with its real default: off.
  'admin-analytics': (
    route: '/settings/analytics',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  // Capacity dials, analytics off: retentionConsequence's ungrounded branch.
  'admin-performance': (
    route: '/settings/performance',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  // Reads only myPermissionsProvider, which fixtureContainer grants in full.
  'admin-account-recovery': (
    route: '/settings/account-recovery',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
};

/// States reachable only by overriding a provider the plain [_surfaces]
/// table above has no way to reach: a bespoke HTTP answer, a forced
/// permission grant, or pre-seeded debug-log entries.
final _overrideSurfaces =
    <
      String,
      ({
        String route,
        List<String> viewports,
        List<Override> Function() overrides,
      })
    >{
      'admin-analytics-populated': (
        route: '/settings/analytics',
        viewports: phoneAndDesktop,
        overrides: () => [
          apiProvider.overrideWith(
            (ref) =>
                _apiWith(ref, {'/space/analytics': fixtureAnalyticsEnabled}),
          ),
        ],
      ),

      /// The long paragraph that grew unnoticed on a phone while nothing
      /// rendered this pane at all.
      ///
      /// Both overrides are load-bearing: `retentionConsequence` returns early
      /// on `days <= 0`, so analytics alone renders this byte-identical to the
      /// plain surface above. The first version of this entry did exactly that
      /// and added four tests that asserted nothing, which only showed up on
      /// comparing the two captures.
      'admin-performance-populated': (
        route: '/settings/performance',
        viewports: phoneAndDesktop,
        overrides: () => [
          apiProvider.overrideWith(
            (ref) => _apiWith(ref, {
              '/space/analytics': fixtureAnalyticsEnabled,
              '/space/retention': const {'retention_days': 90},
            }),
          ),
        ],
      ),
      'admin-removed-members-empty': (
        route: '/settings/removed-members',
        viewports: phoneAndDesktop,
        overrides: () => [
          apiProvider.overrideWith(
            (ref) => _apiWith(ref, {'/members/removed': const <Object>[]}),
          ),
        ],
      ),
      // Direct navigation only: menu and section hide on the same condition.
      'space-settings-no-access': (
        route: '/settings/space',
        viewports: phoneAndDesktop,
        overrides: () => [myPermissionsProvider.overrideWithValue(0)],
      ),
      // One bit only: just the Invites pane, so the nav really is partial.
      'space-settings-partial': (
        route: '/settings/space',
        viewports: phoneAndDesktop,
        overrides: () => [
          myPermissionsProvider.overrideWithValue(Perm.createInvite),
        ],
      ),
      'debug-log-populated': (
        route: '/settings/debug-log',
        viewports: [...phoneAndDesktop, ...compactBracket],
        overrides: () => [
          debugLogProvider.overrideWith((ref) => _populatedDebugLog()),
        ],
      ),
    };

/// A client answering [paths] itself and delegating everything else to the
/// shared fixture, so a surface needing one bespoke response does not have
/// to re-derive the whole switch [fixtureResponse] already carries.
api.SlimmApi _apiWith(Ref ref, Map<String, Object> paths) {
  final client = testApi((request) async {
    final body = paths[request.url.path];
    if (body == null) return fixtureResponse(request);
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }, session: ref.watch(sessionProvider));
  ref.onDispose(client.close);
  return client;
}

/// One entry of each severity, one of them expandable, so a single render
/// proves the plain-row shape, the `ExpansionTile` shape and the colour
/// coding all at once rather than needing three separate fixtures.
DebugLog _populatedDebugLog() => DebugLog()
  ..record(
    'voice',
    'Reconnected to the SFU after a 2s drop',
    level: DiagnosticSeverity.info,
  )
  ..record(
    'platform',
    'Per-participant volume is unsupported on this platform',
    level: DiagnosticSeverity.warning,
  )
  ..record(
    'flutter',
    'A RenderFlex overflowed by 12 pixels on the right',
    level: DiagnosticSeverity.error,
    detail:
        '#0  RenderFlex.performLayout (package:flutter/…)\n'
        '#1  RenderObject.layout (package:flutter/…)',
  );

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const ['dark', 'light']) {
    for (final surface in _surfaces.entries) {
      for (final viewportName in surface.value.viewports) {
        testWidgets(
          '${surface.key} at $viewportName ($theme) fits its viewport',
          (tester) async {
            await renderSurface(
              tester,
              surface.value.route,
              viewportName,
              theme,
              '${surface.key}-$viewportName-$theme',
            );
          },
        );
      }
    }

    for (final surface in _overrideSurfaces.entries) {
      for (final viewportName in surface.value.viewports) {
        testWidgets(
          '${surface.key} at $viewportName ($theme) fits its viewport',
          (tester) async {
            await renderSurface(
              tester,
              surface.value.route,
              viewportName,
              theme,
              '${surface.key}-$viewportName-$theme',
              overrides: surface.value.overrides(),
              // The embedded first pane's fetch resolves past the budget.
              settleNestedResolve: surface.key.startsWith('space-settings'),
            );
          },
        );
      }
    }
  }
}
