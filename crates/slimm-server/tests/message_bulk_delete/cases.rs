// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The tests themselves. See `harness.rs` for the store, router, and request
//! helpers they all share.

use axum::http::StatusCode;
use slimm_server::permissions::Permissions;
use slimm_server::store::RoleChanges;
use uuid::Uuid;

use crate::harness::{
    app, audit, bulk_delete, channel_id, live_count, new_store, ops, people, send,
};

#[tokio::test]
async fn a_moderator_deletes_several_messages_in_one_request() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let mut ids = Vec::new();
    for i in 0..3 {
        ids.push(send(&app, &channel, &member.0, &format!("spam {i}")).await);
    }
    send(&app, &channel, &member.0, "kept").await;

    assert_eq!(
        bulk_delete(&app, &channel, &moderator.0, &ids).await,
        StatusCode::NO_CONTENT
    );

    assert_eq!(
        live_count(&store, &channel).await,
        1,
        "only the message that was not named survives"
    );
    let deletes: Vec<_> = ops(&pool, &channel)
        .await
        .into_iter()
        .filter(|(_, kind)| kind == "delete")
        .collect();
    assert_eq!(
        deletes.len(),
        3,
        "one delete op per message, not one per batch"
    );
}

/// The invariant the client's own cursor rule depends on: every op seq in the
/// channel is consecutive, so a live client can apply the burst rather than
/// falling back to a full REST reconcile.
#[tokio::test]
async fn each_deleted_message_takes_its_own_consecutive_seq() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let mut ids = Vec::new();
    for i in 0..4 {
        ids.push(send(&app, &channel, &member.0, &format!("spam {i}")).await);
    }
    bulk_delete(&app, &channel, &moderator.0, &ids).await;

    let seqs: Vec<i64> = ops(&pool, &channel)
        .await
        .into_iter()
        .map(|(s, _)| s)
        .collect();
    let expected: Vec<i64> = (1..=seqs.len() as i64).collect();
    assert_eq!(
        seqs, expected,
        "the op stream must stay dense; a gap makes every live client resync"
    );
}

/// Deleting an id that is already gone is not an error and writes nothing,
/// the single delete's own idempotence carried over.
#[tokio::test]
async fn an_already_deleted_id_is_skipped_rather_than_re_deleted() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let id = send(&app, &channel, &member.0, "spam").await;
    let ids = vec![id];
    assert_eq!(
        bulk_delete(&app, &channel, &moderator.0, &ids).await,
        StatusCode::NO_CONTENT
    );
    let after_first = ops(&pool, &channel).await.len();

    assert_eq!(
        bulk_delete(&app, &channel, &moderator.0, &ids).await,
        StatusCode::NO_CONTENT,
        "a repeat is a success, not a 404"
    );
    assert_eq!(
        ops(&pool, &channel).await.len(),
        after_first,
        "and it writes no second op, so no client is told twice"
    );
}

/// Nothing is deleted unless every id resolves, so a batch naming one message
/// from another channel leaves the rest of the batch alone.
#[tokio::test]
async fn an_id_from_another_channel_refuses_the_whole_batch() {
    let (store, pool, _guard) = new_store().await;
    let (admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let other = store
        .create_channel("other", "text")
        .await
        .unwrap()
        .id
        .0
        .to_string();
    let app = app(store.clone());

    let here = send(&app, &channel, &member.0, "spam").await;
    let elsewhere = send(&app, &other, &admin.0, "not in this channel").await;

    let status = bulk_delete(&app, &channel, &moderator.0, &[here.clone(), elsewhere]).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    assert_eq!(
        live_count(&store, &channel).await,
        1,
        "the id that was valid must not have been deleted anyway"
    );
    assert!(
        ops(&pool, &channel).await.is_empty(),
        "a refused batch writes no ops at all"
    );
}

/// MANAGE_MESSAGES reaches every message in the channel, an administrator's
/// included, and this pins that rather than leaving it to be inferred.
///
/// It is the same reach the single delete has always had. A guard here would
/// only have meant refusing sixty-four at once while allowing the same
/// sixty-four one at a time, which is a difference in patience rather than in
/// permission - see docs/decisions/0016.
#[tokio::test]
async fn manage_messages_reaches_an_administrators_message_too() {
    let (store, pool, _guard) = new_store().await;
    let (admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let theirs = send(&app, &channel, &member.0, "spam").await;
    let admins = send(&app, &channel, &admin.0, "an administrator speaking").await;

    let status = bulk_delete(&app, &channel, &moderator.0, &[theirs, admins]).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    assert_eq!(
        live_count(&store, &channel).await,
        0,
        "both went, including the one whose author outranks the caller"
    );
    assert_eq!(ops(&pool, &channel).await.len(), 2);
}

#[tokio::test]
async fn more_ids_than_the_cap_is_refused_rather_than_truncated() {
    let (store, _pool, _guard) = new_store().await;
    let (_admin, moderator, _member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let ids: Vec<String> = (0..65).map(|_| Uuid::now_v7().to_string()).collect();
    assert_eq!(
        bulk_delete(&app, &channel, &moderator.0, &ids).await,
        StatusCode::BAD_REQUEST,
        "over the cap must refuse, never silently delete the first 64"
    );
}

/// The other side of the same boundary: exactly `MAX_BULK_DELETE_IDS` (64,
/// see `http/messages_bulk.rs`) must succeed rather than be refused, or the
/// guard has drifted from `>` to `>=` without either test noticing.
#[tokio::test]
async fn exactly_the_cap_succeeds() {
    let (store, _pool, _guard) = new_store().await;
    let (admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    // Round-robin across all three accounts: each has its own per-user Class::Write bucket (30-request burst), so sending all 64 from one would rate-limit before the batch is even built - a limit this test has no interest in exercising.
    let senders = [&admin.0, &moderator.0, &member.0];
    let mut ids = Vec::new();
    for i in 0..64 {
        ids.push(
            send(
                &app,
                &channel,
                senders[i % senders.len()],
                &format!("spam {i}"),
            )
            .await,
        );
    }
    assert_eq!(
        bulk_delete(&app, &channel, &moderator.0, &ids).await,
        StatusCode::NO_CONTENT,
        "exactly the cap must be honored, not refused as if it were over it"
    );
}

/// The act is recorded, one row per author whose messages were removed, naming
/// the moderator who did it - which is the whole point of 0049.
#[tokio::test]
async fn the_act_is_recorded_against_each_author() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let a = send(&app, &channel, &member.0, "spam one").await;
    let b = send(&app, &channel, &member.0, "spam two").await;
    bulk_delete(&app, &channel, &moderator.0, &[a, b]).await;

    let rows = audit(&pool).await;
    assert_eq!(
        rows,
        vec![(
            "messages_deleted".to_owned(),
            Some(moderator.1.0.as_bytes().to_vec()),
            Some(member.1.0.as_bytes().to_vec()),
        )],
        "one row for the one author, naming who acted and who it was about"
    );
}

#[tokio::test]
async fn a_refused_batch_records_no_act() {
    let (store, pool, _guard) = new_store().await;
    let (admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let other = store
        .create_channel("other", "text")
        .await
        .unwrap()
        .id
        .0
        .to_string();
    let app = app(store.clone());

    let here = send(&app, &channel, &member.0, "spam").await;
    let elsewhere = send(&app, &other, &admin.0, "not in this channel").await;
    bulk_delete(&app, &channel, &moderator.0, &[here, elsewhere]).await;

    assert!(
        audit(&pool).await.is_empty(),
        "a refusal is not an act, so the trail must not claim one"
    );
}

/// A member without MANAGE_MESSAGES cannot bulk-delete at all, including their
/// own messages: this route is the moderation verb, and the single delete is
/// still there for an author deleting their own.
#[tokio::test]
async fn bulk_delete_needs_manage_messages_even_for_your_own_messages() {
    let (store, _pool, _guard) = new_store().await;
    let (_admin, _moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let mine = send(&app, &channel, &member.0, "my own message").await;
    assert_eq!(
        bulk_delete(&app, &channel, &member.0, &[mine]).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(live_count(&store, &channel).await, 1);
}

/// The realistic abuse shape this file's header describes: a member without
/// MANAGE_MESSAGES cannot launder deleting somebody else's messages by mixing
/// them into a batch with their own.
#[tokio::test]
async fn bulk_delete_needs_manage_messages_even_mixed_with_your_own_messages() {
    let (store, _pool, _guard) = new_store().await;
    let (admin, _moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let mine = send(&app, &channel, &member.0, "my own message").await;
    let theirs = send(&app, &channel, &admin.0, "not mine to delete").await;
    assert_eq!(
        bulk_delete(&app, &channel, &member.0, &[mine, theirs]).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        live_count(&store, &channel).await,
        2,
        "the batch must be refused whole, not partially applied to the caller's own message"
    );
}

/// Deleting a message has to let go of its attachments, or a purge leaves the
/// rows that keep those files alive and nothing ever reclaims them.
///
/// Linked directly rather than through an upload: what is under test is the
/// release, and the upload path has its own tests.
#[tokio::test]
async fn deleting_releases_the_attachments_the_messages_held() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let id = send(&app, &channel, &member.0, "with a file").await;
    let sha = vec![7u8; 32];
    sqlx::query("INSERT INTO attachments (sha256, size, content_type, created_at) VALUES (?, 1, 'image/png', 1)")
        .bind(sha.clone())
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO message_attachments (message_id, sha256, position) VALUES (?, ?, 0)")
        .bind(Uuid::parse_str(&id).unwrap())
        .bind(sha.clone())
        .execute(&pool)
        .await
        .unwrap();

    bulk_delete(&app, &channel, &moderator.0, &[id]).await;

    let links: i64 = sqlx::query_scalar("SELECT count(*) FROM message_attachments")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(links, 0, "the link must be released with the message");
    let rows: i64 = sqlx::query_scalar("SELECT count(*) FROM attachments")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(rows, 0, "and the now-unreferenced attachment collected");
}

/// A caller who cannot see the channel is refused before the route ever looks
/// for the messages, so its answer cannot be used to find out whether a channel
/// or a message exists - decision 0011's masking rule.
///
/// Both halves matter and they must be indistinguishable: a real id in a hidden
/// channel and an id that exists nowhere have to come back the same way. This
/// was missing when the route first shipped, and reordering the existence
/// lookup ahead of the permission checks passed every other test in this file.
#[tokio::test]
async fn a_caller_who_cannot_see_the_channel_learns_nothing_from_the_answer() {
    let (store, _pool, _guard) = new_store().await;
    let (admin, _moderator, outsider) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let real = send(&app, &channel, &admin.0, "in a channel you cannot see").await;

    // The everyone role loses VIEW_CHANNEL, so the outsider cannot see it at all.
    let everyone = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap();
    store
        .update_role(
            everyone.id,
            RoleChanges {
                permissions: Some(Permissions::NONE),
                ..RoleChanges::default()
            },
        )
        .await
        .unwrap();

    let for_real_id = bulk_delete(&app, &channel, &outsider.0, &[real]).await;
    let invented = Uuid::now_v7().to_string();
    let for_invented = bulk_delete(&app, &channel, &outsider.0, &[invented]).await;

    assert_eq!(for_real_id, StatusCode::FORBIDDEN);
    assert_eq!(
        for_real_id, for_invented,
        "a real id and an invented one must answer identically, or the route \
         says which messages exist in a channel the caller cannot see"
    );
}
