// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How tall a floating dock anchored to the bottom of the screen currently
/// is, so `ToastOverlay` and the canvas overlays can clear it rather than
/// landing on top of a live call's mute or leave-call button.
///
/// A plain [StateProvider] rather than an [InheritedWidget]: `ToastOverlay`
/// sits above every route in `main.dart`, a subtree the dock's own ancestors
/// never reach. An [InheritedWidget] published from inside the canvas pane
/// would be invisible to it for exactly that reason; a provider is visible
/// from anywhere in the same `ProviderScope` regardless of where either side
/// sits in the tree.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The real, measured height of whatever bottom-anchored dock is on screen
/// right now, or 0 when none is. See `DockHeightReporter`, the one writer.
final bottomDockReservationProvider = StateProvider<double>((ref) => 0);

/// How far above the window's bottom edge the call mini-player reaches while it
/// rests in the bottom-right corner, where toasts land too; 0 otherwise.
final miniPlayerReachProvider = StateProvider<double>((ref) => 0);

/// The measured width of that dock, or 0 when none is showing, so a corner
/// readout can tell whether the centred dock reaches it.
final bottomDockWidthProvider = StateProvider<double>((ref) => 0);
