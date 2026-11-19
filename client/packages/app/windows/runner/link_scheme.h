#ifndef RUNNER_LINK_SCHEME_H_
#define RUNNER_LINK_SCHEME_H_

/// Points the user's `slimm://` registration at this copy (or its launcher),
/// so a link opens it however it was installed: the setup registers the
/// scheme, but a zip copy, `install.cmd` and an in-app move into the per-user
/// layout never did, and the browser then silently drops Spotify's redirect.
void RegisterLinkScheme();

#endif  // RUNNER_LINK_SCHEME_H_
