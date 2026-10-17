// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How tall a floating dock anchored to the bottom of the screen currently
/// is, so a [SnackBar] shown from anywhere in the shell can clear it rather
/// than landing on top of a live call's mute or leave-call button.
///
/// A plain [StateProvider] rather than an [InheritedWidget]: `HomeShell`
/// wraps the rail, the conversation pane (where the canvas call dock lives)
/// and the member pane in one shared [Scaffold] (its `showsBothPanes`
/// branch), so a snackbar's own trigger - a rail kebab, a member popover, an
/// admin screen - sits in a sibling subtree the dock's own ancestors never
/// reach. An [InheritedWidget] published from inside the canvas pane would
/// be invisible to a caller outside it for exactly that reason; a provider
/// is visible from anywhere in the same `ProviderScope` regardless of where
/// either side sits in the tree.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The real, measured height of whatever bottom-anchored dock is on screen
/// right now, or 0 when none is. See `DockHeightReporter`, the one writer.
final bottomDockReservationProvider = StateProvider<double>((ref) => 0);
