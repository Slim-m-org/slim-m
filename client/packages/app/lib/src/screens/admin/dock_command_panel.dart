// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One `command` extension point an installed and enabled module declares:
/// a text input and Run button that POST to
/// `/modules/{moduleId}/commands/{command}` and render `{ok, output}` /
/// `{ok: false, error}` inline - see
/// docs/decisions/0021-modules-and-the-dock.md's module-agnostic principle.
/// slim has no notion of what any command does; this panel only offers a
/// way to send it text and see the module's own answer, reusing the same
/// output styling `MessageCodeBlockRunner` uses.
///
/// This does not check client-side whether the viewer holds the command's
/// declared permission before showing the panel: the Dock itself is already
/// gated on MANAGE_SERVER, but a module's own permission is a separate,
/// module-scoped grant an admin may or may not hold, and nothing on this
/// screen surfaces that without re-deriving the role/permission editor's
/// own logic. A caller who lacks it still sees the panel; Run simply comes
/// back 403, surfaced inline through the same `AppErrorState` as any other
/// transport failure - see `api_failure.dart`'s `ForbiddenException`
/// wording, which already reads as "you are not allowed to do that."
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/providers.dart';
import '../../widgets/module_command_output.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';

class DockCommandPanel extends ConsumerStatefulWidget {
  const DockCommandPanel({
    super.key,
    required this.moduleId,
    required this.extensionPoint,
    this.bare = false,
  });

  final String moduleId;
  final api.DockExtensionPoint extensionPoint;

  /// Just the body, for a row of a card the caller already draws.
  final bool bare;

  @override
  ConsumerState<DockCommandPanel> createState() => _DockCommandPanelState();
}

class _DockCommandPanelState extends ConsumerState<DockCommandPanel>
    with GuardedActionState<DockCommandPanel> {
  final _controller = TextEditingController();
  bool _running = false;
  api.RunModuleCommandResult? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
    });
    api.RunModuleCommandResult? result;
    final ok = await guard(
      whatFailed: 'run ${widget.extensionPoint.name}',
      action: () async {
        result = await ref
            .read(apiProvider)
            .runModuleCommand(
              moduleId: widget.moduleId,
              command: widget.extensionPoint.name,
              input: _controller.text,
            );
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      if (ok) _result = result;
    });
  }

  @override
  Widget build(BuildContext context) => widget.bare
      ? _body(context)
      : SettingsSectionCard(
          title: widget.extensionPoint.name,
          children: [_body(context)],
        );

  /// The input, Run button and result, for a card of its own or an open row.
  Widget _body(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final description = widget.extensionPoint.description;
    final result = _result;
    return SettingsCardBlock(
      gap: AppSpacing.s8,
      children: [
        if (description != null)
          Text(
            description,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.s8,
          children: [
            Expanded(
              child: AppInput(
                controller: _controller,
                placeholder: 'Input',
                enabled: !_running,
                onSubmitted: (_) => _run(),
              ),
            ),
            AppButton(
              label: _running ? 'Running...' : 'Run',
              disabled: _running,
              onPressed: _run,
            ),
          ],
        ),
        if (actionError != null)
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        if (result != null)
          ModuleCommandOutput(
            result: result,
            moduleId: widget.moduleId,
            command: widget.extensionPoint.name,
          ),
      ],
    );
  }
}
