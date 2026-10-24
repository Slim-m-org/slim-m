// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading a module's files from the registry it came from.

use sha2::{Digest, Sha256};

use super::Enabled;
use super::fetch::{self, FetchError, fetch_first};
use super::manifest::{IndexEntry, Manifest, parse_index, parse_manifest};
use super::sources::Origin;
use crate::http::error::ApiError;
use crate::media::to_hex;

/// [path] from wherever [origin] keeps its files.
pub(super) async fn fetch_path(
    dock: &Enabled,
    origin: &Origin,
    path: &str,
    limits: fetch::Limits,
) -> Result<Vec<u8>, FetchError> {
    match origin {
        Origin::Remote(bases) => {
            fetch_first(&dock.client, bases, path, &dock.allowed_host, limits).await
        }
        Origin::Dev(root) => fetch::read_local(root, path, limits).await,
    }
}

/// Fetches and validates the module at [id]'s current `manifest.json`,
/// confirming the registry's own `id` field agrees with the path it was
/// fetched at - the same "does not alias a different resource" check
/// `messages::SendError::IdConflict` exists for elsewhere.
pub(super) async fn fetch_manifest(
    dock: &Enabled,
    origin: &Origin,
    id: &str,
) -> Result<Manifest, ApiError> {
    let bytes = fetch_path(
        dock,
        origin,
        &format!("modules/{id}/manifest.json"),
        fetch::Limits::MANIFEST,
    )
    .await?;
    let manifest = parse_manifest(&bytes)?;
    if manifest.id != id {
        return Err(ApiError::UpstreamInvalid(
            "manifest.json's own id does not match the module it was fetched for".to_owned(),
        ));
    }
    Ok(manifest)
}

/// `bases` moved to the immutable ref the index published for `id`, so the
/// manifest an admin reviews and the artifact it installs come from one fixed
/// commit. An entry with no ref (an older index), or an index that cannot be
/// read, leaves `bases` on `main`; the reviewed digest still binds the install.
pub(super) async fn pinned_origin(
    dock: &Enabled,
    origin: &Origin,
    id: &str,
) -> Result<Origin, ApiError> {
    let Origin::Remote(bases) = origin else {
        return Ok(origin.clone());
    };
    let Ok(index) = fetch_index(dock, origin).await else {
        return Ok(origin.clone());
    };
    let Some(reference) = index
        .into_iter()
        .find(|e| e.id == id)
        .and_then(|e| e.reference)
    else {
        return Ok(origin.clone());
    };
    bases
        .iter()
        .map(|base| {
            base.join(&format!("../{reference}/"))
                .map_err(|_| ApiError::Internal)
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Origin::Remote)
}

/// The first of `bases`' `index.json` that exists, fetched capped and validated.
pub(super) async fn fetch_index(
    dock: &Enabled,
    origin: &Origin,
) -> Result<Vec<IndexEntry>, ApiError> {
    let bytes = fetch_path(dock, origin, "index.json", fetch::Limits::INDEX).await?;
    Ok(parse_index(&bytes)?)
}

/// Fetches the module's own artifact bytes at `manifest.artifact.path`,
/// relative to the same allowlisted base the manifest itself came from, and
/// refuses them if their sha256 does not match what the manifest declared -
/// the fetch-time half of the check `crate::module_runtime::ModuleHost`
/// repeats again, defense in depth, right before it ever runs them.
pub(super) async fn fetch_artifact(
    dock: &Enabled,
    origin: &Origin,
    manifest: &Manifest,
) -> Result<Vec<u8>, ApiError> {
    let bytes = fetch_path(
        dock,
        origin,
        &manifest.artifact.path,
        fetch::Limits::ARTIFACT,
    )
    .await?;
    let digest = to_hex(&Sha256::digest(&bytes));
    if digest != manifest.artifact.sha256 {
        return Err(ApiError::UpstreamInvalid(
            "the module artifact's sha256 does not match its manifest".to_owned(),
        ));
    }
    Ok(bytes)
}
