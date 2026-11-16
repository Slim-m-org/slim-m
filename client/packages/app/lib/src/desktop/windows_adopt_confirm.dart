// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one question before a bare Windows copy updates itself: doing so moves
/// the app, so say where and that nothing else changes.
library;

import 'package:flutter/widgets.dart';

import '../widgets/confirm_dialog.dart';

/// True when the person agrees to move this copy into their account's app
/// folder as part of updating.
Future<bool> confirmWindowsAdopt(BuildContext context) => confirmChoice(
  context,
  title: 'Move slim-m to update it?',
  message:
      'This copy runs from a folder. It moves into your account\'s app '
      'folder so it can keep itself up to date. Your settings and '
      'sign-in stay as they are.',
  confirmLabel: 'Move and update',
);
