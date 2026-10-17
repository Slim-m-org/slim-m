// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the canvas has dropped its surrounding chrome to show nothing but
/// the surface.
///
/// The owner asked for this directly, alongside the portrait complaint it
/// ships with: "need a way to sort of fullscreen and just view content in
/// convas on mobile". Read this before adding anything to the list of things
/// fullscreen hides.
///
/// **What it hides, and the one thing it deliberately does not.** The canvas
/// identity strip (`CanvasBar`), the channel rail and the member pane all go.
/// The floating dock stays, in a folded form: `CanvasCallDock` drops the five
/// drawing tools and keeps the call controls, because that file's own doc
/// already fixes the one failure this feature must not reintroduce - "a call
/// nobody can mute or leave is the one failure this dock must never produce".
/// A viewing mode that took the hang-up button away with the toolbar would be
/// exactly that.
///
/// **Entering disarms the pen, and that is not tidiness.** `CanvasSurface`
/// pans and zooms on two pointers only, so a one-finger drag draws with
/// whatever tool is armed. Folding the tool strip away without also changing
/// the tool would leave a mode that reads as "look around" and scribbles on
/// a shared canvas when you do. `_CanvasPaneState` switches to
/// `CanvasTool.pan` on the way in - it places nothing, and on empty space
/// it selects nothing either - and puts the previous tool back on the way
/// out.
///
/// **Keyed on the channel, exactly the shape `canvasOpenProvider` already
/// has.** Fullscreen is a property of one channel's canvas, not of the app,
/// so switching channels leaves it behind with no imperative reset to
/// forget: the id simply stops matching. Coming back to a channel you left
/// in fullscreen returns you to it, the same way coming back to a channel
/// you left with the canvas open reopens the canvas. Closing the canvas
/// clears both.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The channel whose canvas is currently fullscreen, or null.
final canvasFullscreenProvider = StateProvider<String?>((ref) => null);
