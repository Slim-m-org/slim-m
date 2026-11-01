// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin setup, one step at a time. Nothing here saves a setting itself:
/// every step embeds a settings section that writes as it is changed, so
/// Continue only moves on and every step can be passed over.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../first_run/widgets/first_run_frame.dart';
import '../providers/admin_setup_controller.dart';
import 'admin_setup_steps.dart';

/// Wider than the member welcome card: the sections are settings panes.
const double kAdminSetupCardWidth = 640;

class AdminSetupFlow extends ConsumerStatefulWidget {
  const AdminSetupFlow({super.key});

  @override
  ConsumerState<AdminSetupFlow> createState() => _AdminSetupFlowState();
}

class _AdminSetupFlowState extends ConsumerState<AdminSetupFlow> {
  var _step = AdminSetupStep.server;
  var _busy = false;
  String? _error;

  Future<void> _finish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminSetupControllerProvider.notifier).complete();
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'close the admin setup', e, stack);
      if (mounted) _error = 'Not saved: ${e.message}';
    }
    if (mounted) setState(() => _busy = false);
  }

  void _next() {
    if (_step == AdminSetupStep.values.last) {
      unawaited(_finish());
      return;
    }
    setState(() => _step = AdminSetupStep.values[_step.index + 1]);
  }

  void _back() =>
      setState(() => _step = AdminSetupStep.values[_step.index - 1]);

  @override
  Widget build(BuildContext context) {
    final last = _step == AdminSetupStep.values.last;
    return FirstRunFrame(
      step: _step.index,
      stepCount: AdminSetupStep.values.length,
      title: _step.title,
      subtitle: _step.subtitle,
      cardWidth: kAdminSetupCardWidth,
      continueLabel: last ? 'Finish' : 'Continue',
      busy: _busy,
      onContinue: _next,
      onSkip: () => unawaited(_finish()),
      onBack: _step == AdminSetupStep.server ? null : _back,
      error: _error,
      body: AdminSetupStepBody(step: _step),
    );
  }
}
