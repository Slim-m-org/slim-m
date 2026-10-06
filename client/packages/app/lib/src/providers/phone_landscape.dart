// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A portrait-locked phone may rotate only while a call's video is full screen
/// (decision 0058); everything routed below that view keeps its portrait size.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

final orientationChannelProvider = Provider<OrientationChannel>(
  (ref) => OrientationChannel(),
);

/// Set once the native side reports a portrait-locked phone, the only device
/// whose window can turn landscape while the shell must not follow it.
final portraitLockedPhoneProvider = StateProvider<bool>((ref) => false);

/// [data] as the routed app should see it: on a locked phone in landscape the
/// width and height swap back, so the shell never lays out as a wide window.
MediaQueryData keepPortraitShell(
  MediaQueryData data, {
  required bool lockedPhone,
}) {
  final size = data.size;
  if (!lockedPhone || size.width <= size.height) return data;
  return data.copyWith(size: Size(size.height, size.width));
}
