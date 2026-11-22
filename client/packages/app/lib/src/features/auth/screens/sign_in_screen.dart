// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Connecting to a server and signing in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../default_server.dart';
import '../../../providers/providers.dart';
import '../providers/browser_reach.dart';
import '../../../routing/routes.dart';
import '../../../server_address_reduction.dart';
import '../widgets/onboarding_shell.dart';
import '../widgets/server_identity_confirmation.dart';
import '../../../providers/toasts.dart';
import '../../../whats_new/providers/whats_new_controller.dart';
import 'reset_password_sheet.dart';
import 'sign_in_alternatives.dart';
import 'sign_in_connect.dart';
import '../widgets/sign_in_credential_fields.dart';
import '../widgets/server_warnings_modal.dart';
import '../widgets/sign_in_error.dart';
import '../../../invite_link.dart';
import 'sign_in_destination.dart';
import 'sign_in_form_parts.dart';
import 'sign_in_join_steps.dart';
import 'sign_in_probe_controller.dart';
import 'sign_in_server_probe.dart';
import 'sign_in_reason_notices.dart';
import 'sign_in_wording.dart';

/// Sign in or create an account on a chosen server, from one form: the
/// server says whether the username exists, and only a name with no account
/// opens the step that creates one (decision 0130). Opening on either mode by
/// guess made second accounts for people signing back in on a new device.
///
/// The server address is part of this screen rather than buried in settings,
/// because self-hosting is the normal case: which server you are on is a
/// first-class choice, not an advanced option. The one exception is the
/// compiled-in official server, where that choice was already made by
/// picking "Join the official Space" in onboarding: the field stays
/// collapsed so joining it is username and password, nothing else, and
/// "Use a different Space" leads back to onboarding for any other address.
///
/// Creating an account opens in steps (`sign_in_join_steps.dart`), and every
/// state names where it is about to connect (`sign_in_destination.dart`).
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  /// Prefilled from the server chosen during onboarding, which every entry path
  /// has already written; a hardcoded default here silently overrode that
  /// choice on submit.
  late final TextEditingController _server = TextEditingController(
    text: ref.read(serverUrlProvider).toString(),
  );

  /// Whether the address field is on screen. Collapsed for the compiled-in
  /// official server, where an address is not a decision anyone joining it
  /// needs to make; a different address is chosen through onboarding.
  late final bool _addressExpanded = !isOfficialServer(
    ref.read(serverUrlProvider),
  );
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();

  bool _creatingAccount = false;

  /// The username the server said has no account, which the create step names.
  String? _noAccountNamed;

  /// Set once the person picks a mode, so a late probe never switches it.
  bool _modeChosen = false;
  bool _busy = false;

  /// The current failure and the field it belongs to; see [signInErrorFor].
  (SignInErrorField, String)? _error;

  /// A wrong username/password pair lands on the password, as does its own error.
  String? _errorFor(SignInErrorField field) =>
      _error?.$1 == field ||
          (field == SignInErrorField.password &&
              _error?.$1 == SignInErrorField.credentials)
      ? _error!.$2
      : null;

  late final _probe = SignInProbeController(
    SignInProbeHost(
      mounted: () => mounted,
      address: () => _server.text,
      ask: _askServer,
      update: setState,
      onAnswered: (version) {
        if (!_modeChosen && opensOnCreating(version, invited: _invited)) {
          _creatingAccount = true;
        }
      },
    ),
  );

  late final _invite = HeldInvite(
    pending: ref.read(pendingInviteProvider),
    server: probeTarget(_server.text),
  );

  JoinStage get _stage => _invite.stageOn(
    probeTarget(_server.text),
    _probe.probed,
    creating: _creatingAccount,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_probe.probe());
  }

  @override
  void dispose() {
    _probe.dispose();
    _server.dispose();
    _invite.dispose();
    _username.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<ServerAnswer> _askServer(String text) => answerForAddress(
    text,
    probeApi: ref.read(probeApiProvider),
    keyStore: ref.read(keyStoreProvider),
    // Only the create form says why a probe failed, so only it asks the browser.
    reach: _creatingAccount
        ? ref.read(browserReachProbeProvider)
        : (_) async => null,
  );

  /// Continue before the address has answered checks it now, without the debounce.
  Future<void> _checkServer() async {
    _probe.cancelDebounce();
    if (_submittableAddress() == null) return;
    _probe.failureAsked = true;
    await _whileBusy(_probe.probe);
  }

  /// Checks the code on the server in the field before any account field opens.
  Future<void> _checkInvite() async {
    final address = _submittableAddress();
    if (address == null) return;
    final target = reduceServerAddress(address);
    await _whileBusy(() async {
      final client = ref.read(probeApiProvider)(target);
      final problem = await _invite.check(client, target);
      if (mounted && problem != null) {
        setState(() => _error = (SignInErrorField.invite, problem));
      }
    });
  }

  /// Runs [work] with the button busy, and always gives the button back.
  Future<void> _whileBusy(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A whole invite link fills both fields, as it does in the invite dialog;
  /// the server it names is probed like a typed one.
  void _onInviteEdited(String text) {
    if (parseInviteLink(text) case (:final server, :final code)) {
      _invite.controller.text = code;
      final linked = probeTarget(server.toString());
      if (linked != null && linked != probeTarget(_server.text)) {
        _server.text = server.toString();
        _invite.linkTo(linked);
        _onServerEdited(_server.text);
        unawaited(_checkLinkedInvite());
      }
    }
    setState(() {
      if (_error?.$1 == SignInErrorField.invite) _error = null;
    });
  }

  /// The link's own Space answers first, then its code is checked there.
  Future<void> _checkLinkedInvite() async {
    await _checkServer();
    if (mounted && _probe.probed != null) await _checkInvite();
  }

  void _onServerEdited(String _) {
    _clearErrorOn({SignInErrorField.server});
    _reprobe();
  }

  /// The old answer is about the old address the moment the field changes,
  /// and the line naming the destination is read off the field itself.
  /// [keepError] holds a failure just shown, as after a sign-in nothing answered.
  void _reprobe({bool keepError = false}) {
    setState(() {
      _probe.forget();
      if (!keepError && _error?.$1 == SignInErrorField.server) _error = null;
    });
    _probe.probeSoon();
  }

  void _clearErrorOn(Set<SignInErrorField> fields) {
    if (fields.contains(_error?.$1)) setState(() => _error = null);
  }

  /// The reset-code flow, which confirms identity the way [_submit] does and
  /// hands back no session - hence "sign in", rather than signing them in.
  Future<void> _recoverAccount() async {
    final done = await startAccountRecovery(
      context,
      ref,
      probeTarget(_server.text),
    );
    if (done == null) {
      _submittableAddress();
      return;
    }
    if (!done || !mounted) return;
    ref
        .read(toastsProvider.notifier)
        .show(
          'Password set. Sign in with your new password.',
          severity: AppToastSeverity.success,
        );
  }

  /// Checks what can be checked here, then [connectAndSignIn], explaining any failure.
  Future<void> _submit() async {
    final address = _submittableAddress();
    if (address == null) return;
    final missing = missingCredential(
      username: _username.text,
      password: _password.text,
      confirmPassword: _creatingAccount ? _confirmPassword.text : null,
    );
    if (missing != null) return setState(() => _error = missing);
    if (_creatingAccount && !await _acknowledgedWarnings()) return;
    if (!mounted) return;
    final username = _username.text.trim();
    var accountFound = false;

    setState(() {
      _busy = true;
      _error = null;
    });
    // Read before the awaits: the session redirect can dispose this screen mid-flight.
    final justRegistered = ref.read(justRegisteredProvider.notifier);
    try {
      final result = await connectAndSignIn(
        context,
        ref,
        address: address,
        credentials: (username: username, password: _password.text),
        creatingAccount: _creatingAccount,
        invite: _invite.codeFor(probeTarget(_server.text)),
        // Tried unless this server is known to predate the question.
        lookUpUsername: _probe.probed?.usernameCheck != false,
        onAccountFound: () => accountFound = true,
      );
      if (result == ConnectResult.noAccount && mounted) {
        _offerToCreate(username);
      }
    } on UnauthorizedException catch (e, stack) {
      reportFailure(LogTag.auth, 'sign in', e, stack);
      if (!mounted) return;
      setState(
        () => _error = accountFound
            ? wrongPasswordFor(username)
            : signInErrorFor(e),
      );
    } on ApiException catch (e, stack) {
      reportFailure(LogTag.auth, 'sign in', e, stack);
      justRegistered.state = false;
      if (!mounted) return;
      final error = await explainSignInFailure(
        e,
        server: probeTarget(_server.text),
        reach: ref.read(browserReachProbeProvider),
        knownSpace: pinnedIdentityCheck(ref.read(keyStoreProvider)),
        offline: !ref.read(browserOnlineProvider)(),
      );
      if (!mounted) return;
      setState(() => _error = error);
      // What the probe said before is no longer known to hold.
      if (e is TransportException) _reprobe(keepError: true);
    } catch (error, stack) {
      reportFailure(LogTag.auth, 'sign in', error, stack);
      justRegistered.state = false;
      if (mounted) setState(() => _error = unexpectedSignInError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the create step for [username], which the server has no account for.
  void _offerToCreate(String username) {
    setState(() {
      _creatingAccount = true;
      _noAccountNamed = username;
      _confirmPassword.clear();
    });
    // Creating waits on the server, so a failed answer is worth asking again.
    if (_probe.probed == null) unawaited(_checkServer());
  }

  /// An error or notice about the last attempt no longer holds once it changes.
  void _onCredentialsEdited() {
    _clearErrorOn(const {
      SignInErrorField.username,
      SignInErrorField.password,
      SignInErrorField.confirmPassword,
      SignInErrorField.credentials,
      SignInErrorField.form,
    });
    if (_noAccountNamed != null && _noAccountNamed != _username.text.trim()) {
      setState(() => _noAccountNamed = null);
    }
  }

  void _toggleCreating() {
    setState(() {
      _creatingAccount = !_creatingAccount;
      _noAccountNamed = null;
      _modeChosen = true;
      _error = null;
    });
    if (_creatingAccount && _probe.failure != null) unawaited(_checkServer());
  }

  /// Whether onboarding handed this screen an invite, so someone is joining.
  late final bool _invited = ref.read(pendingInviteProvider) != null;

  /// The typed address when it can be submitted; otherwise shows why not.
  Uri? _submittableAddress() {
    final (address, problem) = submittableAddress(_server.text);
    if (problem != null) {
      setState(() => _error = (SignInErrorField.server, problem));
    }
    return address;
  }

  /// Joining is where server warnings matter; signing in never asks.
  Future<bool> _acknowledgedWarnings() {
    final warnings = serverWarningsFor(_probe.probed);
    if (warnings.isEmpty) return Future.value(true);
    return confirmServerWarnings(context, warnings);
  }

  /// Whether this run met the server for the first time just before this
  /// screen; read once, so a sign-in that pins the key does not retitle it.
  late final bool _firstContact = ref
      .read(firstContactServersProvider)
      .contains(identityHandleFor(ref.read(serverUrlProvider)));

  @override
  Widget build(BuildContext context) {
    final firstContact = _firstContact;
    final identityStatus =
        _probe.identityStatus ?? ServerIdentityStatus.unknown;
    final stage = _stage;
    final serverError =
        _errorFor(SignInErrorField.server) ??
        (_creatingAccount && _probe.failureAsked ? _probe.failure : null);

    return OnboardingShell(
      // Creating an account is the last of the join steps; signing back in to
      // a server you already trust is one act and gets no stepper.
      step: _creatingAccount ? OnboardingStep.identity : null,
      version: ref.watch(appInfoProvider).valueOrNull?.version,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SignInDestination(
            title: signInTitle(
              creating: _creatingAccount,
              firstContact: firstContact,
            ),
            host: serverHostLabel(_server.text),
            version: _probe.probed,
            // A key saved moments ago by this connect matches nothing from before.
            status:
                firstContact && identityStatus == ServerIdentityStatus.confirmed
                ? ServerIdentityStatus.unknown
                : identityStatus,
            error: _addressExpanded ? null : serverError,
          ),
          const SignInReasonNotices(),
          if (_addressExpanded)
            SignInServerField(
              controller: _server,
              focusNode: _probe.focusNode,
              error: serverError,
              onChanged: _onServerEdited,
            ),
          SignInNotices(
            probed: _probe.probed,
            creatingAccount: _creatingAccount,
            noAccountNamed: _noAccountNamed,
          ),
          // Each band brings its own gap, so a step not yet open leaves none behind.
          InviteCodeField(
            invite: _invite,
            server: probeTarget(_server.text),
            probed: _probe.probed,
            creatingAccount: _creatingAccount,
            busy: _busy,
            error: _errorFor(SignInErrorField.invite),
            onChanged: _onInviteEdited,
            onSubmit: _checkInvite,
          ),
          AppRevealBand(
            child: stage == JoinStage.account
                ? Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s16),
                    child: SignInCredentialFields(
                      username: _username,
                      password: _password,
                      confirmPassword: _confirmPassword,
                      creatingAccount: _creatingAccount,
                      usernameInvalid:
                          _error?.$1 == SignInErrorField.credentials,
                      busy: _busy,
                      errorFor: _errorFor,
                      onSubmit: _submit,
                      onEdited: _onCredentialsEdited,
                      onRecoverAccount: () => unawaited(_recoverAccount()),
                    ),
                  )
                : null,
          ),
          if (_errorFor(SignInErrorField.form) case final formError?)
            SignInFormError(message: formError),
          const SizedBox(height: AppSpacing.s24),
          AppButton(
            label: switch (stage) {
              JoinStage.account => signInAction(
                creating: _creatingAccount,
                firstContact: firstContact,
              ),
              _ => 'Continue',
            },
            variant: AppButtonVariant.primary,
            size: AppButtonSize.lg,
            full: true,
            busy: _busy,
            onPressed: switch (stage) {
              JoinStage.server => _checkServer,
              JoinStage.invite => _checkInvite,
              JoinStage.account => _submit,
            },
          ),
          const SizedBox(height: AppSpacing.s12),
          // Alternatives to the action above, not a list under it.
          SignInAlternatives(
            creatingAccount: _creatingAccount,
            busy: _busy,
            onToggleCreating: _toggleCreating,
            onUseDifferentSpace: () => context.go(Routes.onboarding),
          ),
        ],
      ),
    );
  }
}
