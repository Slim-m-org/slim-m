// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `/version` says the canvas accepts a scoped clear, so a client can gate the
//! choices on the server rather than guess from its version number.

mod support;

use support::app::call;

#[tokio::test]
async fn version_advertises_the_scoped_clear() {
    let (store, _guard) = support::new_store("slimm-version-scoped-clear").await;
    let router = support::app::router(store);
    let (_, version) = call(&router, "GET", "/version", None, None).await;
    assert_eq!(version["canvas_scoped_clear"], true);
}
