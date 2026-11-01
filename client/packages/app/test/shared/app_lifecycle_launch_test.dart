// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone process launched in the background must not read as focused: the
/// viewing reporter would otherwise keep the account marked as reading.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';

ProviderContainer _container({required bool mobile}) {
  final binding = TestWidgetsFlutterBinding.ensureInitialized()
    ..resetInternalState();
  addTearDown(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  final container = ProviderContainer(
    overrides: [mobileLifecycleHostProvider.overrideWithValue(mobile)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a phone that has not reported a state yet is not focused', () {
    final container = _container(mobile: true);
    expect(container.read(appFocusedProvider), isFalse);
  });

  test('a phone launched in the background stays unfocused until resumed', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final container = _container(mobile: true);
    container.read(appFocusedProvider);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(container.read(appFocusedProvider), isFalse);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(container.read(appFocusedProvider), isTrue);
  });

  test('a desktop window that has not reported a state yet is focused', () {
    final container = _container(mobile: false);
    expect(container.read(appFocusedProvider), isTrue);
  });
}
