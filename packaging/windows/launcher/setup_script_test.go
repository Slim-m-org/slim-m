// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestUninstallRemovesEveryFolderTheLauncherCreates(t *testing.T) {
	data, err := os.ReadFile("../slim-m.iss")
	if err != nil {
		t.Fatal(err)
	}
	var patterns []string
	for _, match := range regexp.MustCompile(`(?m)^\s*DeleteMatching\('([^']+)'\);`).FindAllStringSubmatch(string(data), -1) {
		patterns = append(patterns, match[1])
	}
	for _, folder := range []string{runFolder, runFolder + ".next", runFolder + ".old", versionPrefix + "0.131.0"} {
		removed := false
		for _, pattern := range patterns {
			if ok, _ := filepath.Match(pattern, folder); ok {
				removed = true
			}
		}
		if !removed {
			t.Errorf("uninstalling leaves %s behind", folder)
		}
	}
}
