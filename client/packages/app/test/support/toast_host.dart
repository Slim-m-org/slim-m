// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mounts the app's toast layer in a test app, and lets a test run its timer out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/widgets/toast_overlay.dart';

/// A `MaterialApp.builder` that paints toasts above [child], as the app shell does.
Widget toastHost(BuildContext context, Widget? child) => Stack(
  children: [
    child ?? const SizedBox.shrink(),
    const Positioned.fill(child: ToastOverlay()),
  ],
);

/// Lets every toast raised so far dismiss itself, so no timer outlives the test.
Future<void> expireToasts(WidgetTester tester) =>
    tester.pump(ToastsController.defaultDuration);

/// The messages of the toasts currently up, read without needing the layer mounted.
List<String> toastMessages(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byWidgetPredicate((w) => w is Navigator).first),
).read(toastsProvider).map((t) => t.message).toList();
