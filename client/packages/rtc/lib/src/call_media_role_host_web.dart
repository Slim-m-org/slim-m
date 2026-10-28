// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser has no process environment to export into; see `call_media_role_host_io.dart`.
library;

Map<String, String> hostEnvironment() => const {};

bool hostSetenv(String name, String value) => false;
