// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How a failed hook run is described and where its stats are kept. A hook is
//! run on text its module may not otherwise see, so what it says is never stored.

use crate::http::module_commands::CommandOutcome;
use crate::store::HookDecl;

/// A fixed description of why a hook run failed, by kind, never the module's own words.
pub(crate) fn failure_category(outcome: &CommandOutcome) -> &'static str {
    if !outcome.host_failed {
        return "the hook answered with an error";
    }
    let reason = outcome.payload.as_str();
    if reason.starts_with("module returned a malformed") {
        "the hook's reply was malformed"
    } else if reason.starts_with("module trapped") {
        "the hook trapped"
    } else if reason.starts_with("module exceeded its limits") {
        "the hook ran out of fuel or memory"
    } else if reason.starts_with("module timed out") {
        "the hook ran out of time"
    } else {
        "the hook could not run"
    }
}

/// The run-stats key of one hook, so each hook of a module keeps its own counts.
pub(crate) fn stats_key(command: &str, decl: &HookDecl) -> String {
    if decl.phase.is_empty() {
        format!("{command}:{}", decl.hook)
    } else {
        format!("{command}:{}:{}", decl.hook, decl.phase)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::HookKind;

    #[test]
    fn a_failure_is_described_by_kind_and_never_by_the_modules_text() {
        let said = CommandOutcome {
            ok: false,
            payload: "secret text".into(),
            host_failed: false,
        };
        assert!(!failure_category(&said).contains("secret"));
        let trap = CommandOutcome::host_failure("module trapped: secret".into());
        assert_eq!(failure_category(&trap), "the hook trapped");
        let late = CommandOutcome::host_failure("module timed out".into());
        assert_eq!(failure_category(&late), "the hook ran out of time");
    }

    #[test]
    fn each_hook_of_a_module_has_its_own_key() {
        let decl = |hook: &str, phase: &str| HookDecl {
            kind: HookKind::Interceptor,
            hook: hook.into(),
            phase: phase.into(),
            reads: vec![],
        };
        let a = stats_key("@intercept", &decl("message.pre_send", "reject"));
        let b = stats_key("@intercept", &decl("message.pre_send", "annotate"));
        assert_ne!(a, b);
        assert_eq!(
            stats_key("@allow", &decl("voice.join", "")),
            "@allow:voice.join"
        );
    }
}
