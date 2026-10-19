// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [UpdateWatcher] is the periodic half of the desktop update notice: it
/// must poll on its own schedule (never sooner), stay quiet about a version
/// the user already dismissed, and never run at all when [UpdateWatcher]'s
/// own gate says not to.
///
/// Driven through `fake_async` rather than real delays - `voice_call_heartbeat_test.dart`
/// takes the same approach for the same reason - and through a plain
/// [ProviderContainer] rather than a widget tree, since nothing here renders
/// anything; `update_available_banner_test.dart` covers the widget half.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _interval = Duration(hours: 1);

ClientUpdate _update([String version = '9.9.9']) => ClientUpdate(
  version: version,
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.tarball,
);

/// A check that always answers [found], counting how often it ran.
class _Check {
  _Check(this.found);

  ClientUpdate? found;
  var calls = 0;

  Future<ClientUpdate?> call({
    required String currentVersion,
    http.Client? client,
    InstallFormat? format,
  }) async {
    calls++;
    return found;
  }
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      appInfoProvider.overrideWith(
        (ref) => Future.value(
          PackageInfo(
            appName: 'slim-m',
            packageName: 'top.npcserver.slimm',
            version: '1.0.0',
            buildNumber: '1',
          ),
        ),
      ),
    ],
  );
  return container;
}

/// [UpdateWatcher] takes a [Ref], not a bare [ProviderContainer]; reading it
/// off a throwaway [Provider] is what hands the class under test a real one
/// wired to [container], the same way [updateWatcherProvider] does in the app.
UpdateWatcher _watcher(
  ProviderContainer container, {
  required CheckForClientUpdate check,
  required bool Function() shouldRun,
  Duration? startDelay,
  Stream<void>? secondLaunches,
  DateTime Function()? now,
}) => container.read(
  Provider(
    (ref) => UpdateWatcher(
      ref,
      interval: _interval,
      check: check,
      shouldRun: shouldRun,
      startDelay: startDelay,
      secondLaunches: secondLaunches ?? const Stream.empty(),
      now: now ?? DateTime.now,
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('polls on its interval and not before or more than once per tick', () {
    fakeAsync((async) {
      final check = _Check(null);
      final container = _container();
      final watcher = _watcher(
        container,
        check: check.call,
        shouldRun: () => true,
        now: async.getClock(DateTime(2026)).now,
      );
      addTearDown(watcher.dispose);
      addTearDown(container.dispose);

      watcher.start();
      expect(check.calls, 0, reason: 'no immediate check on start');

      async.elapse(_interval - const Duration(seconds: 1));
      expect(check.calls, 0);

      async.elapse(const Duration(seconds: 1));
      expect(check.calls, 1);

      async.elapse(_interval);
      expect(check.calls, 2);
    });
  });

  test('a found update not previously dismissed is published', () {
    fakeAsync((async) {
      final check = _Check(_update());
      final container = _container();
      final watcher = _watcher(
        container,
        check: check.call,
        shouldRun: () => true,
        now: async.getClock(DateTime(2026)).now,
      );
      addTearDown(watcher.dispose);
      addTearDown(container.dispose);

      watcher.start();
      async.elapse(_interval);

      expect(container.read(inSessionUpdateProvider)?.version, '9.9.9');
    });
  });

  test('a version already dismissed at the splash stays dismissed here', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({
        dismissedUpdateVersionKey: '9.9.9',
      });
      final check = _Check(_update());
      final container = _container();
      final watcher = _watcher(
        container,
        check: check.call,
        shouldRun: () => true,
        now: async.getClock(DateTime(2026)).now,
      );
      addTearDown(watcher.dispose);
      addTearDown(container.dispose);

      watcher.start();
      async.elapse(_interval);

      expect(
        container.read(inSessionUpdateProvider),
        isNull,
        reason: 'the same version was already turned down once',
      );
    });
  });

  test('a genuinely newer version is offered even though an older one was '
      'dismissed', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({
        dismissedUpdateVersionKey: '9.8.0',
      });
      final check = _Check(_update('9.9.9'));
      final container = _container();
      final watcher = _watcher(
        container,
        check: check.call,
        shouldRun: () => true,
        now: async.getClock(DateTime(2026)).now,
      );
      addTearDown(watcher.dispose);
      addTearDown(container.dispose);

      watcher.start();
      async.elapse(_interval);

      expect(container.read(inSessionUpdateProvider)?.version, '9.9.9');
    });
  });

  test('never starts a timer when shouldRun says not to', () {
    fakeAsync((async) {
      final check = _Check(_update());
      final container = _container();
      final watcher = _watcher(
        container,
        check: check.call,
        shouldRun: () => false,
      );
      addTearDown(watcher.dispose);
      addTearDown(container.dispose);

      watcher.start();
      async.elapse(_interval * 10);

      expect(
        check.calls,
        0,
        reason:
            'web, phones, and SLIMM_NO_UPDATE_CHECK all answer through '
            'shouldRun, and none of them may ever poll',
      );
    });
  });

  group('besides the timer', () {
    test('checks once shortly after start', () {
      fakeAsync((async) {
        final check = _Check(null);
        final container = _container();
        final watcher = _watcher(
          container,
          check: check.call,
          shouldRun: () => true,
          startDelay: const Duration(minutes: 1),
          now: async.getClock(DateTime(2026)).now,
        );
        addTearDown(watcher.dispose);
        addTearDown(container.dispose);

        watcher.start();
        async.elapse(const Duration(seconds: 59));
        expect(check.calls, 0);
        async.elapse(const Duration(seconds: 2));
        expect(check.calls, 1);
      });
    });

    test('a second launch checks, but never twice within ten minutes', () {
      fakeAsync((async) {
        final check = _Check(null);
        final launches = StreamController<void>.broadcast();
        final container = _container();
        final watcher = _watcher(
          container,
          check: check.call,
          shouldRun: () => true,
          secondLaunches: launches.stream,
          now: async.getClock(DateTime(2026)).now,
        );
        addTearDown(watcher.dispose);
        addTearDown(container.dispose);
        addTearDown(launches.close);

        watcher.start();
        launches.add(null);
        async.flushMicrotasks();
        expect(check.calls, 1);

        async.elapse(const Duration(minutes: 9));
        launches.add(null);
        async.flushMicrotasks();
        expect(check.calls, 1, reason: 'debounced');

        async.elapse(const Duration(minutes: 2));
        launches.add(null);
        async.flushMicrotasks();
        expect(check.calls, 2);
      });
    });
  });
}
