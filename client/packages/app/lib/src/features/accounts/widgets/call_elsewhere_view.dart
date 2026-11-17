// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Another community's live call, read from its own account, for the places
/// that show it instead of the call pill. See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/server_info.dart';
import '../../../routing/router.dart';
import '../../../routing/routes.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../../voice/providers/dm_call.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../providers/account_providers.dart';
import '../providers/call_elsewhere_shown.dart';
import 'other_account_value.dart';

/// What a place showing another community's call draws, and what it acts on.
class CallElsewhere {
  const CallElsewhere({
    required this.voice,
    required this.channelName,
    required this.community,
    required this.controller,
    required this.open,
  });

  final VoiceFlags voice;

  /// Null until the channel's row has loaded.
  final String? channelName;
  final String community;

  /// That community's own controller, for mute, deafen and leave.
  final VoiceController controller;

  /// Switches to the community, then opens the call's channel there.
  final Future<void> Function() open;

  /// What a screen reader hears for the press that runs [open].
  String get returnLabel => switch (channelName) {
    final channel? => 'Return to call, $channel on $community',
    null => 'Return to call on $community',
  };
}

/// [builder] over [entry]'s call. While it is on screen it counts as a place
/// that shows the call, so the call pill steps aside.
class CallElsewhereView extends ConsumerStatefulWidget {
  const CallElsewhereView({
    super.key,
    required this.entry,
    required this.builder,
  });

  final AccountEntry entry;
  final Widget Function(BuildContext context, CallElsewhere call) builder;

  @override
  ConsumerState<CallElsewhereView> createState() => _CallElsewhereViewState();
}

class _CallElsewhereViewState extends ConsumerState<CallElsewhereView> {
  CallElsewhereShown? _counted;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A route pushed over this place keeps it mounted but off screen, with tickers off.
    final next = TickerMode.valuesOf(context).enabled
        ? ref.read(callElsewhereShownProvider)
        : null;
    if (identical(next, _counted)) return;
    _counted?.remove();
    _counted = next?..add();
  }

  @override
  void dispose() {
    _counted?.remove();
    super.dispose();
  }

  Future<void> _open(String channelId) async {
    final account = widget.entry.container;
    final host = ref.read(accountHostProvider);
    final router = account.read(routerProvider);
    await host?.switchTo(widget.entry.account.origin);
    // A no-op for a real voice channel; load-bearing for a DM.
    account.read(dmCallOpenProvider.notifier).state = channelId;
    router.go(Routes.channel(channelId));
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.entry.container;
    return OtherAccountValue(
      container: account,
      provider: voiceFlagsProvider,
      builder: (context, voice) {
        final channelId = voice.channelId;
        if (channelId == null) return const SizedBox.shrink();
        return OtherAccountValue(
          container: account,
          provider: channelByIdProvider(channelId),
          builder: (context, channel) => OtherAccountValue(
            container: account,
            provider: serverInfoProvider,
            builder: (context, info) => widget.builder(
              context,
              CallElsewhere(
                voice: voice,
                channelName: channel.valueOrNull?.name,
                community:
                    info.valueOrNull?.displayName ??
                    widget.entry.account.serverUrl.host,
                controller: account.read(voiceControllerProvider.notifier),
                open: () => _open(channelId),
              ),
            ),
          ),
        );
      },
    );
  }
}
