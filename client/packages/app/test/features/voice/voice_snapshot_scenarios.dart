// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice-call scenarios `ui_snapshot_test.dart` registers per theme,
/// split out purely for that file's own line budget - every state here
/// still renders through its `_renderSurface`, passed in as [RenderSurface]
/// so this file needs no copy of the viewport table or the router fixture.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart'
    show voiceRosterProvider;
import 'package:slimm_app/src/features/voice/screens/dm_call_pane.dart'
    show dmCallOpenProvider;

import 'voice_snapshot_fixtures.dart';

/// The shape of `ui_snapshot_test.dart`'s own `_renderSurface`: build the
/// router at [route], pump, write the PNG under [snapshotName], assert no
/// overflow. Passed in rather than imported so that function can stay
/// private to its own file.
typedef RenderSurface =
    Future<void> Function(
      WidgetTester tester,
      String route,
      String viewportName,
      String theme,
      String snapshotName, {
      List<Override> overrides,
      bool settleJoinTransition,
    });

const _phoneAndDesktop = ['phone-portrait', 'desktop'];

/// Connected-call variations the matrix's one fixed `voice-in-call` state
/// never shows, because it can only ever be in one shape at a time: nobody
/// sharing (the plain wrapped grid), the local device's own camera or
/// microphone, a mid-call error, the local device sharing its own screen,
/// and iOS's own awaiting-broadcast pending state. See
/// `voice_snapshot_fixtures.dart` for what each `VoiceState` actually sets.
final _voiceCallVariantSurfaces =
    <String, ({String route, List<String> viewports, VoiceState state})>{
      'voice-in-call-grid': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: gridCallState,
      ),
      'voice-in-call-local-camera': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: localCameraCallState,
      ),
      'voice-in-call-error': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: callWithErrorState,
      ),
      'voice-in-call-local-share': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: localSharingCallState,
      ),
      'voice-in-call-share-pending': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: shareAwaitingBroadcastState,
      ),
      'voice-in-call-mic-off': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: localMicOffState,
      ),
    };

/// The join preview's busy-elsewhere switch prompt, which never calls
/// `VoiceController.join`, reached by pinning `voiceControllerProvider`
/// directly. Its connecting state is the `voice` shell surface.
final _voiceJoinPreviewSurfaces =
    <String, ({String route, List<String> viewports, VoiceState state})>{
      'voice-switch-prompt': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: busyElsewhereState,
      ),
    };

/// The rejoin/error family: reachable only through a real (intercepted)
/// `VoiceController.join` call. See `AttemptedJoinVoiceController`'s own doc
/// for why a plain pinned `VoiceState` cannot reach these.
final _voiceRejoinSurfaces =
    <String, ({String route, List<String> viewports, VoiceState state})>{
      'voice-rejoin-recap': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: recapCallState,
      ),
      'voice-rejoin-recap-solo': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: soloRecapCallState,
      ),
      'voice-rejoin-error-retryable': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: rejoinErrorRetryableState,
      ),
      // Proves the join button is absent, not disabled: `canRetry` false.
      'voice-rejoin-error-permanent': (
        route: '/channels/c-main',
        viewports: _phoneAndDesktop,
        state: rejoinErrorPermanentState,
      ),
    };

/// The rejoin screen's own roster preview, forced to two of the three
/// answers `voiceRosterProvider` can give - each paired with
/// [leftPlainState] so the roster is the only thing that varies. The third
/// answer, never-resolved, has its own explicit test in
/// [registerWhoIsHereUnknown] instead, since there is no roster *value* to
/// put in this map.
const _whoIsHereRosters = <String, List<api.VoiceRosterParticipant>>{
  'who-is-here-empty': emptyRoster,
  'who-is-here-populated': populatedRoster,
};

void _pinnedLoop(
  String theme,
  RenderSurface render,
  Map<String, ({String route, List<String> viewports, VoiceState state})> table,
) {
  for (final surface in table.entries) {
    for (final viewportName in surface.value.viewports) {
      testWidgets(
        '${surface.key} at $viewportName ($theme) fits its viewport',
        (tester) async {
          await render(
            tester,
            surface.value.route,
            viewportName,
            theme,
            '${surface.key}-$viewportName-$theme',
            overrides: [
              voiceControllerProvider.overrideWith(
                (ref) => SnapshotVoiceController(ref, surface.value.state),
              ),
            ],
          );
        },
      );
    }
  }
}

/// The local share with a source to switch to, so the dock shows the options
/// caret; `voice-in-call-local-share` above is the same call without it.
void registerVoiceShareOptions(String theme, RenderSurface render) {
  for (final viewportName in _phoneAndDesktop) {
    testWidgets(
      'voice-in-call-local-share-options at $viewportName ($theme) fits its '
      'viewport',
      (tester) async {
        await render(
          tester,
          '/channels/c-main',
          viewportName,
          theme,
          'voice-in-call-local-share-options-$viewportName-$theme',
          overrides: [
            voiceControllerProvider.overrideWith(
              (ref) => SnapshotVoiceController(
                ref,
                localSharingCallState,
                needsSource: true,
              ),
            ),
          ],
        );
      },
    );
  }
}

void registerVoiceCallVariants(String theme, RenderSurface render) =>
    _pinnedLoop(theme, render, _voiceCallVariantSurfaces);

void registerVoiceJoinPreview(String theme, RenderSurface render) =>
    _pinnedLoop(theme, render, _voiceJoinPreviewSurfaces);

void registerVoiceRejoin(String theme, RenderSurface render) {
  for (final surface in _voiceRejoinSurfaces.entries) {
    for (final viewportName in surface.value.viewports) {
      testWidgets(
        '${surface.key} at $viewportName ($theme) fits its viewport',
        (tester) async {
          await render(
            tester,
            surface.value.route,
            viewportName,
            theme,
            '${surface.key}-$viewportName-$theme',
            overrides: [
              voiceControllerProvider.overrideWith(
                (ref) => AttemptedJoinVoiceController(ref, surface.value.state),
              ),
            ],
            settleJoinTransition: true,
          );
        },
      );
    }
  }
}

void registerWhoIsHere(String theme, RenderSurface render) {
  for (final roster in _whoIsHereRosters.entries) {
    testWidgets('${roster.key} ($theme) fits its viewport', (tester) async {
      await render(
        tester,
        '/channels/c-main',
        'phone-portrait',
        theme,
        '${roster.key}-phone-portrait-$theme',
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => AttemptedJoinVoiceController(ref, leftPlainState),
          ),
          voiceRosterProvider(
            'c-main',
          ).overrideWith((ref) => Stream.value(roster.value)),
        ],
        settleJoinTransition: true,
      );
    });
  }
}

void registerWhoIsHereUnknown(String theme, RenderSurface render) {
  testWidgets('who-is-here-unknown ($theme) fits its viewport', (tester) async {
    await render(
      tester,
      '/channels/c-main',
      'phone-portrait',
      theme,
      'who-is-here-unknown-phone-portrait-$theme',
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => AttemptedJoinVoiceController(ref, leftPlainState),
        ),
        // Never emits: the roster stays unresolved, as with no SFU at all.
        voiceRosterProvider('c-main').overrideWith(
          (ref) => const Stream<List<api.VoiceRosterParticipant>>.empty(),
        ),
      ],
      settleJoinTransition: true,
    );
  });
}

void registerDmCall(String theme, RenderSurface render) {
  for (final viewportName in _phoneAndDesktop) {
    testWidgets('dm-call at $viewportName ($theme) fits its viewport', (
      tester,
    ) async {
      await render(
        tester,
        '/channels/$dmChannelId',
        viewportName,
        theme,
        'dm-call-$viewportName-$theme',
        overrides: [
          dmCallOpenProvider.overrideWith((ref) => dmChannelId),
          voiceControllerProvider.overrideWith(
            (ref) => SnapshotVoiceController(ref, dmConnectedCallState),
          ),
        ],
      );
    });
  }
}
