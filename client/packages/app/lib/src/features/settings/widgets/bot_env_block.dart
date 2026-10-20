// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The environment a bot process needs, as one pasteable block.
library;

/// Uses the variable names the bot templates read; see docs/bots/building-bots.md.
String botEnvBlock({required Uri url, required String token}) {
  final origin = url.toString().replaceFirst(RegExp(r'/+$'), '');
  return 'SLIMM_URL=$origin\nSLIMM_BOT_TOKEN=$token\n';
}
