// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join flow's invite entry: [InviteDialog] redeems a code (or a
/// pasted/tapped invite link) and shows the Space's landing card before Join.
/// It only gathers and verifies; identity confirmation and the final choice
/// stay with the screen that opened it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../invite_link.dart';
import '../../settings/providers/display_preferences.dart';
import '../../../providers/providers.dart';
import '../../../routing/page_transitions.dart';
import '../../../server_address_input.dart';
import '../../../server_address_reduction.dart';
import '../../../server_scheme_policy.dart';
import '../../members/widgets/invite_landing_card.dart';
import '../../members/widgets/invite_landing_view.dart';
import '../../../widgets/image_decode.dart';
import '../../../widgets/space_icon.dart';
import 'invite_code_check.dart';

const double _bannerDecodeWidth = 520;

/// Decoded inside a bound the client picks, since this server is not vouched for yet.
ImageProvider _boundedNetworkImage(Uri url, int edge) => ResizeImage(
  NetworkImage(url.toString()),
  width: edge,
  height: edge,
  policy: ResizeImagePolicy.fit,
);

/// Redeeming an invite: check the code against the server before asking anyone
/// to fill in a signup form, and accept the terms at the point of joining.
class InviteDialog extends ConsumerStatefulWidget {
  const InviteDialog({this.initial, this.fullScreen = false, super.key});

  /// Prefill from a tapped invite link. Fills the fields exactly the way a
  /// paste does - every check a typed address clears still runs on it.
  final ({Uri server, String code})? initial;

  /// Draws its own page with a close in the app bar; see [showInviteDialog].
  final bool fullScreen;

  @override
  ConsumerState<InviteDialog> createState() => InviteDialogState();
}

class InviteDialogState extends ConsumerState<InviteDialog> {
  late final _server = TextEditingController(
    text: widget.initial?.server.toString() ?? '',
  );
  late final _code = TextEditingController(text: widget.initial?.code ?? '');
  bool _accepted = false;
  bool _busy = false;
  String? _error;

  /// Set once the code checks out; the sheet then shows the landing card
  /// instead of the form, and Join hands the verified pair back.
  ({
    api.InviteCommunity community,
    Uri banner,
    Uri icon,
    Uri server,
    String code,
  })?
  _landing;

  /// True once a link has named the server, so the address is not asked for
  /// again; "Use a different server" brings the field back.
  late bool _serverFromLink = widget.initial != null;

  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Splits a pasted invite link across both fields, so somebody handed one
  /// string does not have to pull it apart by hand.
  ///
  /// Only fills the fields in. The server it names is exactly as untrusted as
  /// one typed here, so [_verify]'s scheme check, address reduction and live
  /// probe all still run on it - a link must not become a way past guards
  /// that typing has to clear. Anything that is not a link is left alone,
  /// since a bare code pasted into the code field is already correct.
  void _absorbPastedLink(String text) {
    final invite = parseInviteLink(text);
    if (invite == null) return;
    setState(() {
      _server.text = invite.server.toString();
      _code.text = invite.code;
      _serverFromLink = true;
      _error = null;
    });
  }

  String _joiningHost() {
    final host = parseServerAddress(_server.text)?.host ?? '';
    return host.isEmpty ? _server.text.trim() : host;
  }

  Future<void> _verify() async {
    if (looksLikeWebAddress(_code.text)) {
      setState(() => _error = inviteLooksLikeWebAddress);
      return;
    }
    final address = parseServerAddress(_server.text);
    if (address == null) {
      setState(() => _error = serverAddressError(_server.text));
      return;
    }
    if (requireSecureScheme(address) case final schemeError?) {
      setState(() => _error = schemeError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    // Userinfo must never ride along on the probe or persist; see reduceServerAddress.
    final reduced = reduceServerAddress(address);
    // The probe seam confirmServerIdentity uses, so a test can fake this untrusted transport the same way.
    final client = ref.read(probeApiProvider)(reduced);
    try {
      final check = await client.checkInvite(_code.text.trim());
      if (!mounted) return;
      if (check is api.InviteUnusable) {
        setState(() => _error = inviteUnusable);
        return;
      }
      if (check is api.InviteUsable && mounted) {
        final code = _code.text.trim();
        setState(
          () => _landing = (
            community: check.community,
            banner: client.inviteBannerUri(code),
            icon: client.inviteIconUri(code),
            server: reduced,
            code: code,
          ),
        );
      }
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.auth, 'verify the server', e, stack);
      if (!mounted) return;
      setState(() => _error = inviteCheckFailure(e));
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildLanding(
    ({
      api.InviteCommunity community,
      Uri banner,
      Uri icon,
      Uri server,
      String code,
    })
    landing,
  ) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final community = landing.community;
    return InviteLandingView(
      fill: widget.fullScreen,
      onBack: () => setState(() => _landing = null),
      onJoin: () => Navigator.of(context).pop((landing.server, landing.code)),
      card: InviteLandingCard(
        name: community.name,
        memberCount: community.memberCount,
        description: community.description,
        invitedBy: community.invitedBy,
        expiresAt: community.expiresAt,
        use24Hour: watchUse24Hour(ref, context),
        icon: community.iconUpdatedAt == null
            ? null
            : SpaceIconFrame(
                size: kInviteIconSize,
                child: Image(
                  image: _boundedNetworkImage(
                    landing.icon,
                    decodeEdge(
                      context,
                      kInviteIconSize,
                      minRatio: 2,
                      oversample: 3,
                    ),
                  ),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      ColoredBox(color: tokens.surfaceSunken),
                ),
              ),
        banner: community.bannerUpdatedAt == null
            ? null
            : Image(
                image: _boundedNetworkImage(
                  landing.banner,
                  decodeEdge(context, _bannerDecodeWidth),
                ),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    ColoredBox(color: tokens.surfaceSunken),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final landing = _landing;
    final body = landing != null ? _buildLanding(landing) : _buildForm();
    return widget.fullScreen ? _FullScreenFrame(child: body) : body;
  }

  Widget _buildForm() {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final fields = [
      // A full-screen page carries the title in its app bar instead.
      if (!widget.fullScreen) ...[
        Text(
          'Redeem an invite',
          style: AppText.body.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
        const SizedBox(height: AppSpacing.s12),
      ],
      if (_serverFromLink) ...[
        Text(
          'Joining ${_joiningHost()}',
          style: AppText.code.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s12),
      ] else ...[
        AppInput(
          controller: _server,
          placeholder: 'chat.example',
          mono: true,
          keyboardType: TextInputType.url,
          semanticLabel: 'Server',
          onChanged: _absorbPastedLink,
        ),
        const SizedBox(height: AppSpacing.s12),
      ],
      AppInput(
        controller: _code,
        // Either field takes a whole link, because somebody pasting one has no reason to know which half it is.
        placeholder: 'Invite code, or paste an invite link',
        semanticLabel: 'Invite code',
        onChanged: _absorbPastedLink,
      ),
      const SizedBox(height: AppSpacing.s12),
      // Terms are accepted at the point of joining - where the decision actually is, not buried in settings.
      CheckboxListTile(
        value: _accepted,
        onChanged: (v) => setState(() => _accepted = v ?? false),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          'I accept the terms of use for this Space.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: AppSpacing.s4),
        AppErrorState(message: _error!),
      ],
      const SizedBox(height: AppSpacing.s12),
      if (_serverFromLink) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton(
            label: 'Use a different server',
            variant: AppButtonVariant.ghost,
            onPressed: () => setState(() => _serverFromLink = false),
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
      ],
    ];
    final proceed = AppButton(
      label: 'Continue',
      variant: AppButtonVariant.primary,
      full: widget.fullScreen,
      busy: _busy,
      disabled: !_accepted,
      onPressed: _verify,
    );
    if (widget.fullScreen) {
      // The app bar's close is the way out, so Continue stands alone at the thumb's edge.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: fields,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s16,
            ),
            child: proceed,
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...fields,
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(child: proceed),
            ],
          ),
        ],
      ),
    );
  }
}

/// The page the redeem flow fills below [kCompactWidth]: a close in the app
/// bar, and Escape does the same for a narrow desktop window.
class _FullScreenFrame extends StatelessWidget {
  const _FullScreenFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).maybePop();
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            leading: AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Close',
              onPressed: close,
            ),
            title: const Text('Redeem an invite'),
          ),
          body: SafeArea(top: false, child: child),
        ),
      ),
    );
  }
}

/// Shows [InviteDialog]: a dialog or sheet from [showAppSheet] at or above
/// [kCompactWidth], and below it a focused full-screen page rather than a
/// sheet (desktop-vs-mobile.md rule 7's compact shape: an invite expires and
/// asks for a decision).
Future<(Uri, String)?> showInviteDialog(
  BuildContext context, {
  ({Uri server, String code})? initial,
}) {
  if (MediaQuery.sizeOf(context).width >= kCompactWidth) {
    return showAppSheet<(Uri, String)>(
      context,
      builder: (context) => InviteDialog(initial: initial),
    );
  }
  return Navigator.of(context, rootNavigator: true).push<(Uri, String)>(
    fadeThroughRoute(
      context,
      (context) => InviteDialog(initial: initial, fullScreen: true),
    ),
  );
}
