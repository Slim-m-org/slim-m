// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
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
	for _, folder := range []string{runFolder, runFolder + ".next-12", runFolder + ".old-12", versionPrefix + "0.131.0", lockFile} {
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

func TestEveryNewBuildShipsTheRunFolderMarker(t *testing.T) {
	data, err := os.ReadFile("../../../client/packages/app/windows/CMakeLists.txt")
	if err != nil {
		t.Fatal(err)
	}
	install := regexp.MustCompile(`(?m)^\s*install\(FILES\s+"\$\{CMAKE_CURRENT_SOURCE_DIR\}/` + regexp.QuoteMeta(runFolderMarker) + `"\s+DESTINATION\s+"\$\{CMAKE_INSTALL_PREFIX\}"`)
	if !install.Match(data) {
		t.Fatalf("the Windows build does not install %s beside slimm_app.exe", runFolderMarker)
	}
	if _, err := os.Stat("../../../client/packages/app/windows/" + runFolderMarker); err != nil {
		t.Fatal(err)
	}
}

func TestTheRunnerReadsTheVariableTheLauncherSets(t *testing.T) {
	data, err := os.ReadFile("../../../client/packages/app/windows/runner/link_handoff.h")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `kFromLauncherVariable[] = L"`+launcherEnv+`";`) {
		t.Fatalf("link_handoff.h does not read %s, so every launch would hand itself back to the launcher", launcherEnv)
	}
}

func TestTheRunnerHandsOverWithTheArgumentTheLauncherTakes(t *testing.T) {
	data, err := os.ReadFile("../../../client/packages/app/windows/runner/link_handoff.h")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `kHandoffArgument[] = L"`+handoffArgument+`";`) {
		t.Fatalf("link_handoff.h does not pass %s, so the launcher would not wait for the copy handing over", handoffArgument)
	}
}
