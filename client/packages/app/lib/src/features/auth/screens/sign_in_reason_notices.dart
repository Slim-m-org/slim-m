// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notices that say why the sign-in screen is showing when the person did
/// not walk there themselves.
library;

import 'package:flutter/widgets.dart';

import '../../share/widgets/share_waiting_notice.dart';
import 'sign_in_session_ended_notice.dart';

class SignInReasonNotices extends StatelessWidget {
  const SignInReasonNotices({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [SessionEndedNotice(), ShareWaitingNotice()],
  );
}
