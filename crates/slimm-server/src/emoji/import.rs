// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bulk emoji import: seeding a deployment from a directory of images an
//! operator supplies.
//!
//! slim-m bundles no emoji set and fetches none. This is only the machinery
//! that takes a directory, and everything in that directory is content the
//! operator brought and holds the rights to.
//!
//! Each file is one emoji, named after its filename through the same
//! [`super::normalize_name`] the HTTP upload uses, and stored through the same
//! [`super::add_emoji`], so a bulk-imported emoji is indistinguishable from an
//! uploaded one afterwards. The import is not recursive: a subdirectory is
//! reported rather than descended into, because a nested pack is how two files
//! quietly end up claiming one `:shortcode:`.

use std::fmt;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use super::{AddError, MAX_IMAGE_BYTES, MAX_NAME_LEN, NameProblem};
use crate::media::Media;
use crate::store::{MAX_CUSTOM_EMOJI, Store};

/// What happened to one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Added under this name.
    Imported { name: String },
    /// This name already points at exactly these bytes, so an earlier run
    /// imported this file and this one has nothing to do.
    Unchanged { name: String },
    /// This name already belongs to a *different* image, and the existing one
    /// was kept.
    ///
    /// Skipped rather than replaced, deliberately. An import is something an
    /// operator re-runs, often against a directory that has grown since last
    /// time, and replacing would make every re-run silently overwrite emoji
    /// members already recognise, including any that were changed through the
    /// admin UI in between. Skipping makes a re-run's worst case "nothing
    /// happened", which is recoverable by looking at this report; replacing
    /// makes it "the wrong image is now live under a name people use", which
    /// is not. Changing an emoji's image stays an explicit act: delete it,
    /// then import again.
    NameTaken { name: String },
    /// Not imported, and why.
    Refused { reason: Refusal },
    /// Not imported because the deployment is at [`MAX_CUSTOM_EMOJI`]. The
    /// first such file was genuinely attempted; every later one was not,
    /// since the cap cannot fall during an import.
    AtCapacity,
}

/// Why a file was refused. Each is a property of that one file, so the rest
/// of the directory carries on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// The filename leaves nothing typeable between colons.
    UnusableName,
    /// The filename is legal but longer than [`MAX_NAME_LEN`] once
    /// normalised. Its own refusal rather than folded into
    /// [`Refusal::UnusableName`]: a downloaded pack names its files at
    /// length, so this is the common one, and telling an operator their
    /// characters are wrong when they are not is how they go looking in
    /// the wrong place.
    NameTooLong { length: usize },
    /// Not a regular file. Directories land here; the import does not recurse.
    NotAFile,
    /// The filesystem would not hand over the bytes.
    Unreadable(String),
    /// A zero-byte file.
    Empty,
    /// Over [`MAX_IMAGE_BYTES`].
    TooLarge { bytes: u64 },
    /// The bytes are not an image this server stores. Sniffed from the
    /// content, so an extension that lies is caught here.
    NotAnImage,
    /// Wider or taller than an emoji may be.
    TooManyPixels,
    /// The name is a standard unicode emoji's shortcode.
    BuiltinName,
}

/// One line of the report: the filename as the operator wrote it, and what
/// became of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileReport {
    pub file: String,
    pub outcome: Outcome,
}

/// Every file the import looked at, in the order it looked at them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Report {
    pub files: Vec<FileReport>,
}

impl Report {
    /// How many files ended in `outcome`'s variant.
    fn count(&self, matches: impl Fn(&Outcome) -> bool) -> usize {
        self.files.iter().filter(|f| matches(&f.outcome)).count()
    }

    /// Files that are now emoji, whether this run put them there or an
    /// earlier one did.
    pub fn settled(&self) -> usize {
        self.count(|o| matches!(o, Outcome::Imported { .. } | Outcome::Unchanged { .. }))
    }

    /// Files the deployment does not have an emoji for. Non-zero is what
    /// makes the command exit non-zero, so a script notices.
    pub fn unimported(&self) -> usize {
        self.files.len() - self.settled()
    }

    /// Whether every file in the directory is now an emoji.
    pub fn is_clean(&self) -> bool {
        self.unimported() == 0
    }
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let width = self.files.iter().map(|r| r.file.len()).max().unwrap_or(0);
        for report in &self.files {
            writeln!(f, "{:<width$}  {}", report.file, report.outcome)?;
        }
        writeln!(
            f,
            "{} imported, {} unchanged, {} skipped, {} refused, {} over the limit",
            self.count(|o| matches!(o, Outcome::Imported { .. })),
            self.count(|o| matches!(o, Outcome::Unchanged { .. })),
            self.count(|o| matches!(o, Outcome::NameTaken { .. })),
            self.count(|o| matches!(o, Outcome::Refused { .. })),
            self.count(|o| matches!(o, Outcome::AtCapacity)),
        )
    }
}

impl fmt::Display for Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Outcome::Imported { name } => write!(f, "imported as :{name}:"),
            Outcome::Unchanged { name } => {
                write!(f, "unchanged, :{name}: already has these bytes")
            }
            Outcome::NameTaken { name } => {
                write!(f, "skipped, :{name}: already exists with a different image")
            }
            Outcome::Refused { reason } => write!(f, "refused, {reason}"),
            Outcome::AtCapacity => write!(
                f,
                "not imported, this deployment already holds {MAX_CUSTOM_EMOJI} emoji"
            ),
        }
    }
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::UnusableName => {
                write!(f, "the filename leaves no usable name (a-z, 0-9 or _)")
            }
            Refusal::BuiltinName => {
                write!(
                    f,
                    "the name is a standard emoji's shortcode, rename the file"
                )
            }
            Refusal::NameTooLong { length } => write!(
                f,
                "the name is {length} characters, over the {MAX_NAME_LEN} character limit"
            ),
            Refusal::NotAFile => write!(f, "not a regular file, and the import does not recurse"),
            Refusal::Unreadable(err) => write!(f, "unreadable: {err}"),
            Refusal::Empty => write!(f, "the file is empty"),
            Refusal::TooLarge { bytes } => {
                write!(f, "{bytes} bytes, over the {MAX_IMAGE_BYTES} byte limit")
            }
            Refusal::NotAnImage => {
                write!(f, "not a supported image, whatever the extension claims")
            }
            Refusal::TooManyPixels => {
                write!(f, "over {} pixels on a side", crate::media::MAX_EMOJI_SIDE)
            }
        }
    }
}

/// Imports every image in `dir`, returning a line per file.
///
/// Errors only when the database or the blob directory fails, which is not a
/// property of any one file and means the rest of the directory would fail the
/// same way. Everything else is a reported outcome, so one bad file in a pack
/// of two hundred does not end the run. Each emoji is committed on its own, so
/// an abort leaves the ones already imported in place and re-running picks up
/// where it stopped.
pub async fn import_directory(store: &Store, media: &Media, dir: &Path) -> anyhow::Result<Report> {
    let mut files = Vec::new();
    let mut at_capacity = false;

    for path in sorted_entries(dir)? {
        let file = path
            .file_name()
            .unwrap_or(path.as_os_str())
            .to_string_lossy()
            .into_owned();
        let outcome = if at_capacity {
            Outcome::AtCapacity
        } else {
            import_one(store, media, &path).await?
        };
        at_capacity = at_capacity || outcome == Outcome::AtCapacity;
        files.push(FileReport { file, outcome });
    }

    Ok(Report { files })
}

/// Directory entries sorted by path, so two runs over one directory import in
/// the same order and a report can be compared against an earlier one.
fn sorted_entries(dir: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut entries = Vec::new();
    let listing = std::fs::read_dir(dir)
        .map_err(|err| anyhow::anyhow!("reading {}: {err}", dir.display()))?;
    for entry in listing {
        entries.push(entry?.path());
    }
    entries.sort();
    Ok(entries)
}

async fn import_one(store: &Store, media: &Media, path: &Path) -> anyhow::Result<Outcome> {
    // Synchronous I/O: this runs from the import command, never on a request
    // path, so a blocking read costs nothing a request would notice.
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(err) => return Ok(refused(Refusal::Unreadable(err.to_string()))),
    };
    if !metadata.is_file() {
        return Ok(refused(Refusal::NotAFile));
    }
    // Read from the size on disk, so an enormous file is refused without
    // being pulled into memory first.
    if metadata.len() > MAX_IMAGE_BYTES {
        return Ok(refused(Refusal::TooLarge {
            bytes: metadata.len(),
        }));
    }

    let stem = path.file_stem().and_then(|stem| stem.to_str());
    let name = match stem.map(super::normalize_name) {
        Some(Ok(name)) => name,
        Some(Err(NameProblem::TooLong { length })) => {
            return Ok(refused(Refusal::NameTooLong { length }));
        }
        // A stem that is not UTF-8 has no usable characters either, and the
        // normaliser would drop every one of them.
        Some(Err(NameProblem::Unusable)) | None => {
            return Ok(refused(Refusal::UnusableName));
        }
    };
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(err) => return Ok(refused(Refusal::Unreadable(err.to_string()))),
    };

    // Asked before writing anything, so a re-import neither rewrites blobs nor
    // has to tell an old import from a collision after the fact.
    if let Some(existing) = store.custom_emoji_sha256_by_name(&name).await? {
        let same = existing == Sha256::digest(&bytes).as_slice();
        return Ok(if same {
            Outcome::Unchanged { name }
        } else {
            Outcome::NameTaken { name }
        });
    }

    match super::add_emoji(store, media, &name, bytes, None).await {
        Ok(_) => Ok(Outcome::Imported { name }),
        Err(AddError::Full) => Ok(Outcome::AtCapacity),
        Err(AddError::NameTaken) => Ok(Outcome::NameTaken { name }),
        Err(AddError::UnusableName) => Ok(refused(Refusal::UnusableName)),
        Err(AddError::BuiltinName) => Ok(refused(Refusal::BuiltinName)),
        Err(AddError::Empty) => Ok(refused(Refusal::Empty)),
        Err(AddError::TooLarge) => Ok(refused(Refusal::TooLarge {
            bytes: metadata.len(),
        })),
        Err(AddError::UnsupportedType) => Ok(refused(Refusal::NotAnImage)),
        Err(AddError::TooManyPixels) => Ok(refused(Refusal::TooManyPixels)),
        Err(AddError::Storage(err)) => Err(err.context(format!("importing {}", path.display()))),
    }
}

fn refused(reason: Refusal) -> Outcome {
    Outcome::Refused { reason }
}
