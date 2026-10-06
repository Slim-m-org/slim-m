// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// While the biometric lock is up, nothing may reach the routed app beneath
/// it: not keyboard focus or a shortcut, not a screen reader's traversal, not
/// the system back button. Driven through the real `appChromeBuilder` over a
/// real go_router stack, the way `SlimMApp` mounts them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/providers/app_lock_controller.dart';
import 'package:slimm_app/src/providers/app_lock_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/app_lock_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Biometric implements BiometricAuthChannel {
  BiometricAuthResult result = BiometricAuthResult.failure;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<BiometricAuthResult> authenticate(String reason) async => result;
}

class _NoopWindow implements AppLockWindowChannel {
  @override
  Future<void> setPrivacyShield(bool enabled) async {}
}

class _Harness {
  final composer = TextEditingController();
  final submitted = <String>[];
  var shortcutFired = 0;
  final biometric = _Biometric();
  late final ProviderContainer container;
  late final GoRouter router;

  void lock() =>
      container.read(appLockControllerProvider.notifier).armOnLaunch();
}

Future<_Harness> _pump(WidgetTester tester) async {
  final h = _Harness();
  h.container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      biometricAuthChannelProvider.overrideWithValue(h.biometric),
      appLockWindowChannelProvider.overrideWithValue(_NoopWindow()),
    ],
  );
  addTearDown(h.container.dispose);
  addTearDown(h.composer.dispose);
  await h.container.read(appLockPreferenceProvider.notifier).set(true);
  h.router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
                h.shortcutFired++,
          },
          child: Scaffold(
            body: Column(
              children: [
                TextField(
                  autofocus: true,
                  controller: h.composer,
                  decoration: const InputDecoration(
                    labelText: 'Message composer',
                  ),
                  onSubmitted: h.submitted.add,
                ),
                TextButton(
                  onPressed: () => context.push('/second'),
                  child: const Text('push'),
                ),
              ],
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/second',
        builder: (_, _) => const Scaffold(body: Text('second page')),
      ),
    ],
  );
  addTearDown(h.router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: h.router,
        builder: appChromeBuilder,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

bool _focusIsOnLockScreen() {
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null) return false;
  var inside = false;
  focus.visitAncestorElements((element) {
    if (element.widget is AppLockScreen) inside = true;
    return !inside;
  });
  return inside || focus.widget is AppLockScreen;
}

/// The live semantics tree's labels; `find.bySemanticsLabel` can match a render object whose subtree was excluded after it painted.
String _semanticsLabels(WidgetTester tester) {
  final labels = StringBuffer();
  void walk(SemanticsNode node) {
    labels.writeln(node.label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return labels.toString();
}

Future<void> _tabAround(WidgetTester tester, {int times = 12}) async {
  for (var i = 0; i < times; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a composer focused before the lock stops taking input', (
    tester,
  ) async {
    final h = await _pump(tester);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    h.lock();
    await tester.pumpAndSettle();
    expect(find.text('slim-m is locked'), findsOneWidget);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'typed behind the lock'),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(h.submitted, isEmpty, reason: 'Enter submitted the hidden composer');
    expect(h.composer.text, isEmpty, reason: 'text reached the hidden field');
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
  });

  testWidgets('Tab and Shift+Tab never leave the lock screen', (tester) async {
    final h = await _pump(tester);
    h.lock();
    await tester.pumpAndSettle();

    await _tabAround(tester);
    expect(_focusIsOnLockScreen(), isTrue, reason: 'Tab left the lock screen');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await _tabAround(tester);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    expect(_focusIsOnLockScreen(), isTrue, reason: 'Shift+Tab left it');
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
  });

  testWidgets('a keyboard shortcut bound in the routed app does not fire', (
    tester,
  ) async {
    final h = await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    expect(h.shortcutFired, 1, reason: 'the control: unlocked it must fire');

    h.lock();
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    expect(h.shortcutFired, 1, reason: 'a shortcut acted on the locked app');
  });

  testWidgets('the routed app is out of the semantics tree while locked', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final h = await _pump(tester);
    expect(_semanticsLabels(tester), contains('Message composer'));
    expect(_semanticsLabels(tester), contains('push'));

    h.lock();
    await tester.pumpAndSettle();

    final labels = _semanticsLabels(tester);
    expect(labels, contains('slim-m is locked'));
    expect(labels, isNot(contains('Message composer')));
    expect(labels, isNot(contains('push')));
    handle.dispose();
  });

  testWidgets('system back leaves the routed stack alone while locked', (
    tester,
  ) async {
    final h = await _pump(tester);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsOneWidget);

    h.lock();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('slim-m is locked'), findsOneWidget);
    expect(find.text('second page'), findsOneWidget, reason: 'back popped it');
  });

  testWidgets('unlocking gives the app back its focus, semantics and back', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final h = await _pump(tester);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    h.lock();
    await tester.pumpAndSettle();

    h.biometric.result = BiometricAuthResult.success;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('slim-m is locked'), findsNothing);
    expect(find.text('second page'), findsOneWidget);
    expect(_semanticsLabels(tester), contains('second page'));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsNothing);
    expect(_semanticsLabels(tester), contains('Message composer'));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    handle.dispose();
  });
}
