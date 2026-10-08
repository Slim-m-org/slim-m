// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the camera-on-join preference: it persists, reaches the next
/// join call this same session (not merely the toggle's own visual state),
/// and its accessible name holds up against the real dumped semantics tree.
///
/// Split out of `voice_settings_screen_test.dart` once this preference joined
/// it and pushed that file over the 500-line hard ceiling; both share
/// `voice_settings_screen_harness.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_settings_screen_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'turning on camera-on-join persists it and reaches the next join',
    (tester) async {
      final session = FakeSession();
      await tester.pumpWidget(
        wrap(
          const VoiceSettingsBody(),
          overrides: [
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
          ],
        ),
      );
      await tester.pumpAndSettle();

      final cameraToggle = find.byWidgetPredicate(
        (w) =>
            w is AppToggle &&
            w.semanticLabel == 'Join calls with your camera on',
      );
      // The capability check section pushes this below the initial viewport.
      await tester.scrollUntilVisible(
        cameraToggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(cameraToggle);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('slimm.voice.camera_on_join'), isTrue);

      final controller = ProviderScope.containerOf(
        tester.element(find.byType(VoiceSettingsBody)),
      ).read(voiceControllerProvider.notifier);
      await controller.join('channel-1');

      expect(
        session.askedForCameraOnJoin,
        isTrue,
        reason:
            'flipping the toggle must reach the join call this session, '
            'not merely the toggle\'s own visual state',
      );
      await controller.leave();
    },
  );

  testWidgets(
    'the camera-on-join toggle carries its own real name and toggle action, '
    'checked against the dumped tree rather than assumed',
    (tester) async {
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(wrap(const VoiceSettingsBody()));
      await tester.pumpAndSettle();

      final cameraToggle = find.byWidgetPredicate(
        (w) =>
            w is AppToggle &&
            w.semanticLabel == 'Join calls with your camera on',
      );
      await tester.scrollUntilVisible(
        cameraToggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      // The device card's rows share one merged ancestor, so ask by name.
      final node = tester.getSemantics(
        find.bySemanticsLabel('Join calls with your camera on'),
      );
      expect(node.label, contains('Join calls with your camera on'));
      expect(
        node.label,
        isNot(contains('camera off')),
        reason:
            'a state-conditional label merged with this row\'s own '
            'fixed one and read as contradictory once actually toggled off',
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      final owner = tester.binding.renderViews.first.owner!;
      final dump = owner.semanticsOwner!.rootSemanticsNode!.toStringDeep();
      expect(
        dump.contains('Microphone input level'),
        isTrue,
        reason:
            'the sibling section keeps its own label, unmerged with '
            "this toggle's",
      );
      semantics.dispose();
    },
  );
}
