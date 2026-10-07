// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the in-call switch camera button is drawn, shared by the controls
/// that draw it and the dock that sizes its row around it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_controller.dart';

/// The deduplicated camera count on a picker platform.
///
/// Unresolved reads as "cannot switch" rather than flashing the button on and
/// off: duplicate device nodes made a wrong count worse than a late one.
final cameraDeviceCountProvider = FutureProvider.autoDispose
    .family<int, VoiceController>(
      (ref, controller) async => (await controller.cameraDevices()).length,
    );

/// Whether [controller] can switch cameras: a bare flip, or more than one device.
bool canSwitchCamera(WidgetRef ref, VoiceController controller) =>
    controller.canFlipCamera ||
    (ref.watch(cameraDeviceCountProvider(controller)).valueOrNull ?? 0) > 1;
