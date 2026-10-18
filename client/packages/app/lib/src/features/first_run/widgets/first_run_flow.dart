// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The four setup steps, in order, and what each one saves on Continue.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Channel;

import '../../../providers/providers.dart';
import '../../../routing/routes.dart';
import '../../settings/providers/notification_preference_controller.dart';
import '../providers/first_run_controller.dart';
import '../providers/first_run_rules.dart';
import 'first_run_device_steps.dart';
import 'first_run_frame.dart';
import 'first_run_profile_steps.dart';

enum FirstRunStep { welcome, you, notifications, voice }

class FirstRunFlow extends ConsumerStatefulWidget {
  const FirstRunFlow({super.key});

  @override
  ConsumerState<FirstRunFlow> createState() => _FirstRunFlowState();
}

class _FirstRunFlowState extends ConsumerState<FirstRunFlow> {
  final _pronouns = TextEditingController();
  final _continueFocus = FocusNode();
  var _step = FirstRunStep.welcome;
  api.NotificationPreference? _notify;
  String? _pronounsSeed;
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _focusContinue();
  }

  @override
  void dispose() {
    _pronouns.dispose();
    _continueFocus.dispose();
    super.dispose();
  }

  void _focusContinue() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _continueFocus.requestFocus();
  });

  Future<void> _continue() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final saved = await _saveStep();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!saved) return;
    if (_step == FirstRunStep.voice) {
      await _finish();
      return;
    }
    setState(() => _step = FirstRunStep.values[_step.index + 1]);
    _focusContinue();
  }

  Future<bool> _saveStep() async {
    try {
      switch (_step) {
        case FirstRunStep.you:
          await _savePronouns();
        case FirstRunStep.notifications:
          await _saveNotifyChoice();
        case FirstRunStep.welcome || FirstRunStep.voice:
          break;
      }
      return true;
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'save the welcome step', e, stack);
      _error = 'Not saved: ${e.message}';
      return false;
    }
  }

  Future<void> _savePronouns() async {
    final me = ref.read(meProvider).valueOrNull;
    final text = _pronouns.text.trim();
    if (text == (me?.pronouns ?? '')) return;
    await ref.read(apiProvider).updateMe(pronouns: text);
    ref.invalidate(meProvider);
  }

  Future<void> _saveNotifyChoice() async {
    final choice = _notify;
    if (choice == null) return;
    if (choice == ref.read(notificationPreferenceProvider).valueOrNull) return;
    try {
      await ref.read(apiProvider).setNotificationPreference(choice);
    } on api.NotFoundException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'The server has no notification setting to save; skipping it',
        error,
        stack,
      );
      // A server too old for the route has nothing to save; the step still counts.
      return;
    }
    ref.invalidate(notificationPreferenceProvider);
  }

  Future<void> _finish() async {
    final controller = ref.read(firstRunControllerProvider.notifier);
    final replay = ref.read(firstRunControllerProvider).replay;
    final channels = replay ? <Channel>[] : await controller.channels();
    final landing = pickLandingChannel(channels);
    await controller.complete(voiceHint: voiceChannelsOf(channels).isNotEmpty);
    if (landing != null && mounted) context.go(Routes.channel(landing.id));
  }

  Future<void> _skip() =>
      ref.read(firstRunControllerProvider.notifier).complete();

  void _back() {
    setState(() => _step = FirstRunStep.values[_step.index - 1]);
    _focusContinue();
  }

  void _seedPronouns() {
    final me = ref.watch(meProvider).valueOrNull;
    if (me == null || _pronounsSeed != null) return;
    _pronounsSeed = _pronouns.text = me.pronouns ?? '';
  }

  @override
  Widget build(BuildContext context) {
    _seedPronouns();
    final (title, subtitle) = switch (_step) {
      FirstRunStep.welcome => ('Welcome', null),
      FirstRunStep.you => (
        'Set up your profile',
        'Add a picture so people know it is you.',
      ),
      FirstRunStep.notifications => (
        'Choose your notifications',
        'You can change this any time in Settings.',
      ),
      FirstRunStep.voice => (
        'Check your voice',
        'Pick the devices a call uses.',
      ),
    };
    final last = _step == FirstRunStep.voice;
    return FirstRunFrame(
      step: _step.index,
      stepCount: FirstRunStep.values.length,
      title: title,
      subtitle: subtitle,
      continueFocus: _continueFocus,
      continueLabel: last ? 'Finish' : 'Continue',
      busy: _busy,
      onContinue: () => unawaited(_continue()),
      onSkip: () => unawaited(_skip()),
      onBack: _step == FirstRunStep.welcome ? null : _back,
      error: _error,
      body: switch (_step) {
        FirstRunStep.welcome => const FirstRunWelcomeStep(),
        FirstRunStep.you => FirstRunYouStep(pronouns: _pronouns),
        FirstRunStep.notifications => FirstRunNotificationsStep(
          choice: _notify,
          onChoice: (value) => setState(() => _notify = value),
        ),
        FirstRunStep.voice => const FirstRunVoiceStep(),
      },
    );
  }
}
