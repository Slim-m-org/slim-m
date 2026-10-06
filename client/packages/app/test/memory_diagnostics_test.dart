// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The memory readout: byte formatting reads at a glance, and the panel
/// renders its lines without depending on a running process.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/memory_diagnostics.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('sizes read like every other byte size in the app', (
    tester,
  ) async {
    final cache = PaintingBinding.instance.imageCache;
    final before = cache.maximumSizeBytes;
    addTearDown(() => cache.maximumSizeBytes = before);
    cache.clear();
    cache.maximumSizeBytes = 150 * 1024 * 1024;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: MemoryDiagnostics()),
        ),
      ),
    );
    expect(find.text('0 B of 150.0 MB'), findsOneWidget);
  });

  testWidgets('renders the image-cache line against its cap', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: MemoryDiagnostics()),
        ),
      ),
    );
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Image cache'), findsOneWidget);
    expect(find.text('Image cache entries'), findsOneWidget);
    // The refresh control is present.
    expect(find.byIcon(AppIcons.retry), findsOneWidget);
  });
}
