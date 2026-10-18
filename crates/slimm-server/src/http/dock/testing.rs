// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The constructors integration tests use to point a real [`Dock`] at a
//! local fake upstream instead of `raw.githubusercontent.com`.

use url::Url;

use super::Dock;
use crate::config::Config;

impl Dock {
    /// An enabled Dock pointed at a local fake upstream, for a test that
    /// drives the real router. [base_url] must end in `/`; its host becomes
    /// the allowlisted one, and the guard resolver allows private addresses
    /// so the loopback a fake upstream binds to is reachable.
    pub fn for_test(base_url: &str) -> Self {
        let parsed = Url::parse(base_url).expect("test base url must parse");
        let repos = vec!["official/addons".to_owned()];
        Self::from_parts(parsed.clone(), repos, vec![parsed], true)
    }

    /// [`Dock::for_test`] with the operator's local `dev` source on, reading `dev_dir`.
    pub fn for_test_with_dev(base_url: &str, dev_dir: &std::path::Path) -> Self {
        Self::for_test(base_url).with_dev_dir(dev_dir.to_str())
    }

    /// An enabled Dock whose official source is `config`'s, read from under
    /// `root` (a local fake upstream) instead of the real host, so a test
    /// exercises the same slug fallback production does.
    pub fn for_test_rooted(root: &str, config: &Config) -> Self {
        let parsed = Url::parse(root).expect("test root url must parse");
        Self::rooted_at(parsed, config.addons_repos(), true)
    }
}
