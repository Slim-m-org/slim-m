// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Push-to-talk bound to a key the scene grid also uses (Space, an arrow):
/// holding it to talk draws no keyboard ring and moves or reveals no cell.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/push_to_talk_listener.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import '../../support/module_scene_fixtures.dart';
import '../voice/voice_controller_harness.dart';

const _tokens = AppTokens.dark;

final _ring = find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).border ==
          Border.all(color: _tokens.focusRing, width: 2),
);

final _grid = find.bySemanticsLabel(RegExp('^Scene grid'));

void main() {
  final desktop = TargetPlatformVariant.only(TargetPlatform.linux);
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  Future<(VoiceController, List<String>)> mount(
    WidgetTester tester, {
    required LogicalKeyboardKey talkKey,
    bool pushToTalk = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.push_to_talk_enabled': pushToTalk,
      'slimm.voice.push_to_talk_key_id': talkKey.keyId,
    });
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    final actions = <String>[];
    var gen = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, _tokens),
          home: PushToTalkListener(
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  child: ModuleSceneView(
                    initial: parseModuleScene(sceneJson(0))!,
                    runCommand: (input) async {
                      actions.add(jsonDecode(input)['action'] as String);
                      return api.RunModuleCommandResult(
                        ok: true,
                        output: sceneJson(++gen),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await pumpFrames(tester);
    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await pumpFrames(tester);
    return (controller, actions);
  }

  for (final talkKey in [
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.arrowRight,
  ]) {
    testWidgets('holding ${talkKey.debugName} to talk leaves the grid alone', (
      tester,
    ) async {
      final (controller, actions) = await mount(tester, talkKey: talkKey);
      final sent = actions.length;
      await controller.toggleMicrophone();
      await pumpFrames(tester);
      expect(controller.state.microphoneEnabled, isFalse, reason: 'baseline');

      await tester.sendKeyDownEvent(talkKey);
      await tester.sendKeyRepeatEvent(talkKey);
      await pumpFrames(tester);

      expect(controller.state.microphoneEnabled, isTrue, reason: 'talking');
      expect(_ring, findsNothing);
      await tester.sendKeyUpEvent(talkKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFrames(tester);
      expect(actions.skip(sent), ['toggle:0,0'], reason: 'the cursor stayed');
      await controller.leave();
    }, variant: desktop);
  }

  testWidgets('with push-to-talk off, Space still reveals the cell', (
    tester,
  ) async {
    final (controller, actions) = await mount(
      tester,
      talkKey: LogicalKeyboardKey.space,
      pushToTalk: false,
    );
    final sent = actions.length;

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await pumpFrames(tester);

    expect(_ring, findsOneWidget);
    expect(actions.skip(sent), ['toggle:0,0']);
    await controller.leave();
  }, variant: desktop);
}
