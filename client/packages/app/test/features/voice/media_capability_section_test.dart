// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the device capability check: nothing runs until asked, a
/// successful probe shows each capability's real answer, and a probe that
/// cannot finish reads as "could not tell" rather than a false "unsupported".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show AppLog;
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/widgets/media_capability_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

class _FakeProbe implements MediaDevicesProbe {
  _FakeProbe({this.micTracks, this.cameraTracks = 0, this.screenSources});

  final int? micTracks;
  final int? cameraTracks;
  final int? screenSources;

  @override
  Future<int> countMicrophoneTracks() async => micTracks!;

  @override
  Future<int> countCameraTracks() async => cameraTracks!;

  @override
  Future<int> countScreenSources() async => screenSources!;
}

/// Never resolves the way [MediaCapabilities.probeAll] promises to: it throws
/// outright, the shape the UI must treat as "could not tell" rather than
/// quietly reporting both capabilities as missing.
class _ThrowingCapabilities extends MediaCapabilities {
  const _ThrowingCapabilities();

  @override
  Future<Map<String, CapabilityResult>> probeAll() async {
    throw StateError('capability probe exploded');
  }
}

/// Lets a test hold the microphone half of the probe open, so the in-flight
/// state can be observed before it resolves.
class _DelayedProbe implements MediaDevicesProbe {
  final micCompleter = Completer<int>();

  @override
  Future<int> countMicrophoneTracks() => micCompleter.future;

  @override
  Future<int> countCameraTracks() async => 1;

  @override
  Future<int> countScreenSources() async => 1;
}

Widget _wrap(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: const Scaffold(body: MediaCapabilitySection()),
    ),
  );
}

void main() {
  testWidgets('nothing is claimed until the button is pressed', (tester) async {
    final container = ProviderContainer(
      overrides: [
        mediaCapabilitiesProvider.overrideWithValue(
          MediaCapabilities(probe: _FakeProbe(micTracks: 0, screenSources: 0)),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    expect(find.text('Check this device'), findsOneWidget);
    expect(find.text('Microphone'), findsNothing);
    expect(find.text('Camera'), findsNothing);
    expect(find.text('Screen capture'), findsNothing);
    expect(find.textContaining('Could not tell'), findsNothing);
  });

  testWidgets("a successful check shows each capability's real answer", (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        mediaCapabilitiesProvider.overrideWithValue(
          MediaCapabilities(
            probe: _FakeProbe(micTracks: 2, cameraTracks: 1, screenSources: 0),
          ),
        ),
      ],
    );
    AppLog.install(container.read(debugLogProvider.notifier));
    addTearDown(() {
      AppLog.install(null);
      container.dispose();
    });

    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.text('Check this device'));
    await tester.pumpAndSettle();

    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Works on this device.'), findsNWidgets(2));
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Screen capture'), findsOneWidget);
    expect(
      find.textContaining(
        'Not working: the portal offered no capturable sources',
      ),
      findsOneWidget,
    );
    expect(find.text('Check again'), findsOneWidget);

    final entries = container.read(debugLogProvider);
    expect(entries, isNotEmpty);
    expect(entries.first.source, 'voice');
    expect(entries.first.level, DiagnosticSeverity.info);
  });

  testWidgets('a probe that throws renders as unknown, not unsupported', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        mediaCapabilitiesProvider.overrideWithValue(
          const _ThrowingCapabilities(),
        ),
      ],
    );
    AppLog.install(container.read(debugLogProvider.notifier));
    addTearDown(() {
      AppLog.install(null);
      container.dispose();
    });

    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.text('Check this device'));
    await tester.pumpAndSettle();

    // The message is a fixed sentence; the raw exception is the mono detail below it, never what a user reads.
    expect(
      find.text('Could not tell what this device supports.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('capability probe exploded'),
      findsOneWidget,
      reason: 'the raw failure still reaches the technical detail line',
    );
    expect(find.text('Microphone'), findsNothing);
    expect(find.textContaining('Not working'), findsNothing);

    final entries = container.read(debugLogProvider);
    expect(entries, isNotEmpty);
    expect(entries.first.source, 'voice');
    expect(entries.first.level, DiagnosticSeverity.warning);
  });

  testWidgets('an in-flight check disables the button until it resolves', (
    tester,
  ) async {
    final probe = _DelayedProbe();
    final container = ProviderContainer(
      overrides: [
        mediaCapabilitiesProvider.overrideWithValue(
          MediaCapabilities(probe: probe),
        ),
      ],
    );
    AppLog.install(container.read(debugLogProvider.notifier));
    addTearDown(() {
      AppLog.install(null);
      container.dispose();
    });

    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.text('Check this device'));
    await tester.pump();

    expect(find.text('Checking...'), findsOneWidget);
    final button = tester.widget<AppButton>(find.byType(AppButton));
    expect(button.onPressed, isNull);

    probe.micCompleter.complete(1);
    await tester.pumpAndSettle();

    expect(find.text('Check again'), findsOneWidget);
  });
}
