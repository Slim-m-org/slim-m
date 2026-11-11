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
import '../../../push/providers/push_controller.dart';
import '../../../api_failure.dart';
import 'first_run_device_steps.dart';
import 'first_run_notifications_step.dart';
import 'first_run_frame.dart';
import 'first_run_profile_steps.dart';
import '../../members/providers/member_actions.dart';
import '../../settings/providers/settings_actions.dart';

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
  var _asked = false;
  var _levelsSkipped = false;

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
    await _advance();
  }

  Future<void> _advance() async {
    if (_step == FirstRunStep.voice) {
      await _finish();
      return;
    }
    setState(() {
      _error = null;
      _step = FirstRunStep.values[_step.index + 1];
      if (_step == FirstRunStep.notifications && _blocked) {
        _levelsSkipped = true;
        _step = FirstRunStep.voice;
      }
    });
    _focusContinue();
  }

  PushStatus get _push => ref.read(pushControllerProvider);
  bool get _blocked => _push == PushStatus.registeredNotificationsBlocked;
  bool get _asking =>
      _step == FirstRunStep.notifications &&
      !_asked &&
      firstRunAsksPermission(_push);

  /// The OS answers inside register; only a grant leads on to the levels.
  Future<void> _allow() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref.read(pushControllerProvider.notifier).register();
    if (!mounted) return;
    setState(() => _busy = false);
    if (_push == PushStatus.registered) {
      setState(() => _asked = true);
      _focusContinue();
      return;
    }
    _levelsSkipped = true;
    await _advance();
  }

  Future<void> _decline() async {
    _levelsSkipped = true;
    await _advance();
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
      final what = reportFailureSentence(
        api.LogTag.ui,
        'save your choices',
        e,
        stack,
      );
      _error = '$what Try again, or skip this for now and change it later.';
      return false;
    }
  }

  Future<void> _savePronouns() async {
    final me = ref.read(meProvider).valueOrNull;
    final text = _pronouns.text.trim();
    if (text == (me?.pronouns ?? '')) return;
    await ref.read(memberActionsProvider).updateMe(pronouns: text);
    ref.invalidate(meProvider);
  }

  Future<void> _saveNotifyChoice() async {
    final choice = _notify;
    if (choice == null) return;
    if (choice == ref.read(notificationPreferenceProvider).valueOrNull) return;
    try {
      await ref.read(settingsActionsProvider).setNotificationPreference(choice);
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
    await controller.complete();
    if (landing != null && mounted) context.go(Routes.channel(landing.id));
  }

  Future<void> _skip() =>
      ref.read(firstRunControllerProvider.notifier).complete();

  void _back() {
    setState(() {
      _error = null;
      _step = FirstRunStep.values[_step.index - 1];
      if (_step == FirstRunStep.notifications && _levelsSkipped) {
        _levelsSkipped = false;
        if (!firstRunAsksPermission(_push)) _step = FirstRunStep.you;
      }
    });
    _focusContinue();
  }

  void _seedPronouns() {
    final me = ref.watch(meProvider).valueOrNull;
    if (me == null || _pronounsSeed != null) return;
    _pronounsSeed = _pronouns.text = me.pronouns ?? '';
  }

  (String, String?) _heading(bool asking) => switch (_step) {
    FirstRunStep.welcome => ('Welcome', null),
    FirstRunStep.you => (
      'Set up your profile',
      'Add a picture, pick a pattern, or keep your initials.',
    ),
    FirstRunStep.notifications when asking => (
      'Turn on notifications',
      'Your phone needs your permission first.',
    ),
    FirstRunStep.notifications => (
      'Choose your notifications',
      'You can change this any time in Settings.',
    ),
    FirstRunStep.voice => ('Check your voice', 'Pick the devices a call uses.'),
  };

  Widget _body(bool asking) => switch (_step) {
    FirstRunStep.welcome => const FirstRunWelcomeStep(),
    FirstRunStep.you => FirstRunYouStep(pronouns: _pronouns),
    FirstRunStep.notifications when asking => const FirstRunPermissionAsk(),
    FirstRunStep.notifications => FirstRunLevelStep(
      choice: _notify,
      onChoice: (value) => setState(() => _notify = value),
    ),
    FirstRunStep.voice => const FirstRunVoiceStep(),
  };

  @override
  Widget build(BuildContext context) {
    _seedPronouns();
    ref.watch(pushControllerProvider);
    final asking = _asking;
    final (title, subtitle) = _heading(asking);
    // A step that was skipped is not counted, so the dots stay honest.
    final skipsNotifications = _levelsSkipped || (_blocked && !_asked);
    final past = skipsNotifications && _step.index > 2;
    final (secondary, onSecondary) = _error != null
        ? ('Skip for now', _advance)
        : asking
        ? ('Not now', _decline)
        : (null, null);
    return FirstRunFrame(
      step: _step.index - (past ? 1 : 0),
      stepCount: FirstRunStep.values.length - (skipsNotifications ? 1 : 0),
      title: title,
      subtitle: subtitle,
      continueFocus: _continueFocus,
      continueLabel: asking
          ? 'Allow'
          : _step == FirstRunStep.voice
          ? 'Finish'
          : 'Continue',
      busy: _busy,
      onContinue: () => unawaited(asking ? _allow() : _continue()),
      onSkip: () => unawaited(_skip()),
      onBack: _step == FirstRunStep.welcome ? null : _back,
      error: _error,
      onRetry: () => unawaited(_continue()),
      secondaryLabel: secondary,
      onSecondary: onSecondary == null ? null : () => unawaited(onSecondary()),
      body: _body(asking),
    );
  }
}
