// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// swapIn puts the linked tree next in place of run. Renaming the whole folder
// keeps it all one version at every moment, but Windows refuses that while any
// file in it is open, and Explorer keeps the exe of a copy it started open
// after that copy exits, until it lets go of its process. Then the files move
// one by one, the exe last; an interruption leaves a mix that the next start
// sees as stale and relinks before anything runs from it.
func swapIn(next, run, old string) error {
	err := renameAside(run, old)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return swapFiles(next, run, old)
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

// swapFiles moves each file of run aside into old and the one from next into
// its place, then moves aside whatever run holds that next does not.
func swapFiles(next, run, old string) error {
	files, err := relativeFiles(next)
	if err != nil {
		return err
	}
	sort.SliceStable(files, func(i, j int) bool { return !isAppExe(files[i]) && isAppExe(files[j]) })
	wanted := make(map[string]bool, len(files))
	for _, rel := range files {
		wanted[strings.ToLower(rel)] = true
		if err := moveAside(run, old, rel); err != nil {
			return err
		}
		if err := renamePath(filepath.Join(next, rel), filepath.Join(run, rel)); err != nil {
			return err
		}
	}
	stale, err := relativeFiles(run)
	if err != nil {
		return err
	}
	for _, rel := range stale {
		if !wanted[strings.ToLower(rel)] {
			if err := moveAside(run, old, rel); err != nil {
				return err
			}
		}
	}
	return nil
}

func isAppExe(rel string) bool { return strings.EqualFold(rel, appExecutable) }

// moveAside renames run's copy of rel, if any, into old, which Windows allows for a file held open with delete sharing.
func moveAside(run, old, rel string) error {
	target := filepath.Join(run, rel)
	if _, err := os.Lstat(target); errors.Is(err, fs.ErrNotExist) {
		return os.MkdirAll(filepath.Dir(target), 0o755)
	}
	if err := os.MkdirAll(filepath.Dir(filepath.Join(old, rel)), 0o755); err != nil {
		return err
	}
	return renamePath(target, filepath.Join(old, rel))
}

func relativeFiles(dir string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		rel, err := filepath.Rel(dir, path)
		files = append(files, rel)
		return err
	})
	return files, err
}
