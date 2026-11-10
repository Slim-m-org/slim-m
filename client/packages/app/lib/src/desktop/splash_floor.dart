// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A minimum visible duration for [StartupScreen], so a warm desktop start
/// still reads as a splash rather than flashing past in a frame or two.
///
/// Desktop only: a phone's splash is held to the first sync catch-up instead,
/// and is not gated on reduce-motion since a held static frame does not move.
library;

import 'dart:async';

import 'package:slimm_design_system/design_system.dart' show AppMotion;
import 'package:slimm_platform/platform.dart' show isDesktopHost;

/// How long [StartupScreen] must stay up on a desktop host before
/// [awaitBootstrapWithSplashFloor] lets readiness flip.
///
/// Its own value rather than an [AppMotion] token: a dwell is not an animation,
/// and 280ms and 560ms both still read as a flicker when the owner ran them.
const Duration minSplashDuration = Duration(milliseconds: 900);

/// Runs [bootstrap] to completion, and on [desktop] also waits out [floor] -
/// whichever finishes later.
///
/// The two run concurrently, so a bootstrap slower than the floor is never
/// delayed by it. [desktop] exists so tests can drive both branches, and a zero
/// [floor] (the splash preference off) adds no perceptible wait.
Future<void> awaitBootstrapWithSplashFloor(
  Future<void> Function() bootstrap, {
  bool? desktop,
  Duration floor = minSplashDuration,
}) async {
  final onDesktop = desktop ?? isDesktopHost;
  final floorFuture = onDesktop ? Future<void>.delayed(floor) : null;
  await bootstrap();
  if (floorFuture != null) await floorFuture;
}
