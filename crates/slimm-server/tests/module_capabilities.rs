// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `kv.store` and the approval gate of decision 0023 through the real command
//! route: what a module may do is what its manifest declared and an admin
//! approved, bounded per module, isolated between modules, wiped on uninstall.
//! Each wasm fixture drives `slim.host_call` for real; the module's output is
//! the host's own response with quotes turned into `'`.

use serde_json::json;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
};

mod support;
use support::module_world::{Install, kv_request, post_request, world};
use support::wasm_fixtures::{host_call_loop_wasm, sha256_hex};

#[tokio::test]
async fn an_approved_module_remembers_state_across_runs_and_a_reinstall() {
    let w = world("slimm-modcap-persist").await;
    let set = kv_request("set", "score", Some("42"));
    w.install(Install {
        id: "ladder",
        wasm: host_call_loop_wasm(&set, 1),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    assert_eq!(w.answer("ladder").await, "{'ok':true}");

    // A new build of the same module reads what the old one wrote.
    let get = kv_request("get", "score", None);
    w.install(Install {
        id: "ladder",
        wasm: host_call_loop_wasm(&get, 1),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    assert_eq!(w.answer("ladder").await, "{'ok':true,'value':'42'}");
}

#[tokio::test]
async fn a_module_is_refused_every_capability_it_was_not_approved_for() {
    let w = world("slimm-modcap-refused").await;
    let get = host_call_loop_wasm(&kv_request("get", "k", None), 1);
    let refused = "module declares an import, which v1 modules may not do";

    w.install(Install {
        id: "declares-nothing",
        wasm: get.clone(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    assert_eq!(w.answer("declares-nothing").await, refused);

    w.install(Install {
        id: "declared-not-approved",
        wasm: get.clone(),
        declared: &["kv.store"],
        approved_host: &[],
    })
    .await;
    assert_eq!(w.answer("declared-not-approved").await, refused);

    w.install(Install {
        id: "approved-not-declared",
        wasm: get,
        declared: &[],
        approved_host: &["kv.store"],
    })
    .await;
    assert_eq!(w.answer("approved-not-declared").await, refused);

    // Approved for one capability, it still cannot reach another.
    let post = post_request("00000000-0000-0000-0000-000000000000", "hi");
    w.install(Install {
        id: "wrong-capability",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["kv.store", "message.post"],
        approved_host: &["kv.store"],
    })
    .await;
    assert_eq!(
        w.answer("wrong-capability").await,
        "{'error':'capability not approved: message.post','ok':false}"
    );
}

#[tokio::test]
async fn a_module_installed_before_approval_existed_gains_nothing() {
    let w = world("slimm-modcap-legacy").await;
    let wasm = host_call_loop_wasm(&kv_request("get", "k", None), 1);
    // The state a pre-0087 row is in: declared in the manifest, never approved.
    w.install(Install {
        id: "old-module",
        wasm: wasm.clone(),
        declared: &["kv.store", "message.post"],
        approved_host: &[],
    })
    .await;
    let row = w
        .store
        .installed_module("old-module")
        .await
        .unwrap()
        .unwrap();
    assert!(row.approved_host_capabilities.is_empty());
    assert!(w.answer("old-module").await.contains("may not do"));

    // Once approved it works, until an upgrade's manifest stops declaring it.
    w.store
        .set_module_host_capabilities("old-module", &["kv.store".to_owned()])
        .await
        .unwrap();
    assert_eq!(w.answer("old-module").await, "{'ok':true,'value':null}");
    let sha256 = sha256_hex(&wasm);
    let run_command = [ModuleExtensionPointSpec {
        kind: "command",
        name: "run",
        description: None,
        permission: Some("run"),
        command: None,
        language: None,
    }];
    let run_permission = [ModulePermissionSpec {
        key: "run",
        name: "Run",
        description: "run it",
    }];
    w.store
        .install_module_with_artifact(
            InstallModuleRequest {
                id: "old-module",
                name: "Scorekeeper",
                version: "0.2.0",
                artifact_sha256: &sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &run_permission,
                extension_points: &run_command,
            },
            &wasm,
        )
        .await
        .unwrap();
    assert!(w.answer("old-module").await.contains("may not do"));
}

#[tokio::test]
async fn the_byte_quota_refuses_the_write_that_would_exceed_it() {
    let w = world("slimm-modcap-quota").await;
    let value = "v".repeat(4000);
    let set = kv_request("set", "k@@", Some(&value));
    // 16 values of about 4 KB fit in the 64 KiB cap; the 17th does not.
    w.install(Install {
        id: "hoarder",
        wasm: host_call_loop_wasm(&set, 17),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    assert_eq!(
        w.answer("hoarder").await,
        "{'error':'kv.store is full for this module','ok':false}"
    );
    assert_eq!(
        w.store.module_kv_keys("hoarder", 100).await.unwrap().len(),
        16
    );
}

#[tokio::test]
async fn the_entry_quota_is_enforced_by_the_durable_store() {
    let w = world("slimm-modcap-entries").await;
    w.install(Install {
        id: "keeper",
        wasm: host_call_loop_wasm(&kv_request("get", "k", None), 1),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    let s = &w.store;
    s.module_kv_set("keeper", "a", "1", 2, 1000).await.unwrap();
    s.module_kv_set("keeper", "b", "1", 2, 1000).await.unwrap();
    assert!(s.module_kv_set("keeper", "c", "1", 2, 1000).await.is_err());
    s.module_kv_set("keeper", "a", "2", 2, 1000)
        .await
        .expect("overwriting a key spends no new entry");
}

#[tokio::test]
async fn one_module_cannot_read_anothers_data() {
    let w = world("slimm-modcap-isolation").await;
    w.install(Install {
        id: "module-a",
        wasm: host_call_loop_wasm(&kv_request("set", "secret", Some("a-only")), 1),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    w.install(Install {
        id: "module-b",
        wasm: host_call_loop_wasm(&kv_request("get", "secret", None), 1),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    w.install(Install {
        id: "module-c",
        wasm: host_call_loop_wasm(&json!({"capability":"kv.store","op":"list"}).to_string(), 1),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    assert_eq!(w.answer("module-a").await, "{'ok':true}");
    assert_eq!(w.answer("module-b").await, "{'ok':true,'value':null}");
    assert_eq!(w.answer("module-c").await, "{'keys':[],'ok':true}");
}

#[tokio::test]
async fn uninstalling_wipes_the_modules_data_and_a_reinstall_starts_empty() {
    let w = world("slimm-modcap-uninstall").await;
    let set = host_call_loop_wasm(&kv_request("set", "score", Some("42")), 1);
    let install = || Install {
        id: "ladder",
        wasm: set.clone(),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    };
    w.install(install()).await;
    w.answer("ladder").await;
    assert_eq!(
        w.store.module_kv_keys("ladder", 10).await.unwrap(),
        ["score"]
    );

    assert!(w.store.uninstall_module("ladder").await.unwrap());
    assert!(
        w.store
            .module_kv_keys("ladder", 10)
            .await
            .unwrap()
            .is_empty()
    );

    w.install(install()).await;
    assert_eq!(
        w.store.module_kv_get("ladder", "score").await.unwrap(),
        None
    );
}
