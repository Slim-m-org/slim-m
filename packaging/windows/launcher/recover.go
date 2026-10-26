// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"os"
	"path/filepath"
	"strings"
)

// locate returns the install root; the copy inside a version folder looks one level up.
func locate(self string) string {
	dir := filepath.Dir(self)
	if strings.HasPrefix(filepath.Base(dir), versionPrefix) {
		if parent := filepath.Dir(dir); read(parent, currentFile) != "" {
			return parent
		}
	}
	return dir
}

// restoreLauncher puts self back at the root when an interrupted swap left none.
func restoreLauncher(root, self string) {
	target := filepath.Join(root, launcherName)
	if target == self {
		return
	}
	if _, err := os.Stat(target); err == nil {
		return
	}
	_ = copyFile(self, target)
}
