// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the extraction sweep and the search hit's attachment name do around
//! the edges: a message whose own text matches never names its attachment,
//! and a caught-up sweep skips its lookup until a send links something.

use super::text_search::world;

#[tokio::test]
async fn a_message_whose_own_text_matches_does_not_name_its_attachment() {
    let w = world().await;
    w.send(
        "the zebrafish report",
        "notes.txt",
        b"zebrafish everywhere".to_vec(),
    )
    .await;
    w.extract().await;

    let found = w.search("zebrafish").await;

    assert_eq!(found.len(), 1);
    assert!(found[0].get("matched_attachment_id").is_none());
}

#[tokio::test]
async fn a_caught_up_pass_skips_the_lookup_until_a_message_links_an_attachment() {
    let w = world().await;
    w.send("first", "first.txt", b"the first okapi".to_vec())
        .await;
    assert_eq!(w.extract().await, 1);

    // Forgetting a marker makes the file eligible again without any link, so only a lookup would see it.
    sqlx::query("DELETE FROM attachment_text")
        .execute(&w.pool)
        .await
        .unwrap();
    assert_eq!(
        w.extract().await,
        0,
        "nothing was linked since the last pass"
    );

    w.send("second", "second.txt", b"the second okapi".to_vec())
        .await;
    assert_eq!(w.extract().await, 2, "a new link wakes the pass up");
}
