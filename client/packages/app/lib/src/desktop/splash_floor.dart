// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A minimum visible duration for [StartupScreen], so a warm desktop start -
/// whose bootstrap often resolves in a frame or two - still reads as a real
/// splash rather than flashing invisibly, per the owner's own report that no
/// splash was perceptible on desktop at all.
///
/// Desktop only. A phone's splash is held to the first sync catch-up instead
/// (`shouldShowBootSplash`); forcing this floor there too would only add
/// latency to every phone cold start.
///
/// Not gated on reduce-motion. [minSplashDuration] holds a static frame on
/// screen for longer, it does not animate one: [StartupScreen]'s own
/// [AppFadeIn] already collapses to an instant landing under reduce-motion,
/// which is the actual motion this app owes that setting. A floor with
/// nothing moving carries none of the vestibular concern reduce-motion
/// exists for.
library;

import 'dart:async';

import 'package:slimm_design_system/design_system.dart' show AppMotion;
import 'package:slimm_platform/platform.dart' show isDesktopHost;

/// How long [StartupScreen] must stay up on a desktop host before
/// [awaitBootstrapWithSplashFloor] lets readiness flip, even when bootstrap
/// itself finishes sooner.
///
/// Deliberately its own value rather than an [AppMotion] token. This first
/// shipped as [AppMotion.slow] on the reasoning that the floor should never
/// ask for more patience than the chrome's own 280ms ceiling - but that
/// ceiling governs how long a thing may take to *move*, and this governs how
/// long a finished screen simply *sits there*. A dwell is not an animation,
/// so borrowing the animation ceiling was the wrong yardstick, and at 280ms
/// the screen still read as a flicker rather than a splash (owner, after
/// running it).
///
/// Doubled to 560ms next, which still was not enough (owner, again, after a
/// second real run) - the mark alone, adrift in a full desktop window, gave
/// the eye nothing to land on before it was gone. [StartupScreen] now pairs
/// the mark with the wordmark so there is a real composition to register,
/// and this floor moves again, to 900ms: past the 560ms result that still
/// read as a glitch, short of a second doubling that would tax every warm
/// launch for a screen that only needs to be *seen*, not read. It stays a
/// floor, never an added delay: a bootstrap slower than this is still the
/// only thing anyone waits on.
const Duration minSplashDuration = Duration(milliseconds: 900);

/// Runs [bootstrap] to completion, and on [desktop] also waits out [floor] -
/// whichever finishes later.
///
/// The two run concurrently, not back to back: the floor starts counting
/// before [bootstrap] is awaited, so a bootstrap slower than the floor is
/// never delayed by it, and only a bootstrap faster than the floor waits out
/// the remainder. [desktop] defaults to [isDesktopHost] (a getter, so it
/// cannot be a default parameter value directly) and exists as a parameter
/// purely so tests can drive both branches without a real host.
///
/// [floor] defaults to [minSplashDuration] for callers with nothing else to
/// say. `main.dart` passes [Duration.zero] when the splash preference is
/// turned off, which still runs this same concurrent-wait shape rather than
/// skipping it - a zero floor resolves as soon as the event loop next turns,
/// so it adds no perceptible wait on top of [bootstrap] without needing a
/// second code path.
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
