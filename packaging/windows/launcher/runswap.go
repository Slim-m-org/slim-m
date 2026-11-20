// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"io/fs"
)

// swapIn puts the linked tree next in place of run by renaming whole folders
// only, so run always holds one version. When run cannot be moved, as while
// Explorer still holds the exe of a copy it started, it is left as it is and
// this start uses the version folder; a later start relinks it.
func swapIn(next, run, old string) error {
	if err := renameAside(run, old); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := renamePath(next, run); err != nil {
		_ = renamePath(old, run)
		return err
	}
	return nil
}

// renameAside moves the run folder out of the way, retrying while something briefly holds one of its files.
func renameAside(run, old string) error {
	var err error
	for i := 0; i < renameTries; i++ {
		if err = renamePath(run, old); err == nil || errors.Is(err, fs.ErrNotExist) {
			return err
		}
		if i+1 < renameTries {
			pause(releasePoll)
		}
	}
	return err
}
