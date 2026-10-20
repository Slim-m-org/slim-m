// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wraps the signed-in shell and shows a form a bot opens the moment it
/// arrives, wherever the member is. Like the what's-new gate, the form is a
/// notice on top of the current screen, not a route.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/bot_forms.dart';
import 'bot_form_sheet.dart';

class BotFormGate extends ConsumerWidget {
  const BotFormGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<List<BotFormRequest>>(botFormsProvider, (previous, next) {
      if (next.isEmpty) return;
      // A post-frame callback, since showing a sheet mid-build is not allowed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        for (final request in ref.read(botFormsProvider.notifier).takeAll()) {
          unawaited(showBotFormSheet(context, request));
        }
      });
    });
    return child;
  }
}
