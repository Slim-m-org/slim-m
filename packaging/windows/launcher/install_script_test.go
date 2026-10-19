// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// installScript is install.ps1 with comments removed, so a comment cannot satisfy a check.
func installScript(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile("../install.ps1")
	if err != nil {
		t.Fatal(err)
	}
	var kept []string
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "#") {
			kept = append(kept, line)
		}
	}
	return strings.Join(kept, "\n")
}

func TestInstallScriptNeverHidesAFailedDelete(t *testing.T) {
	script := installScript(t)
	if regexp.MustCompile(`Remove-Item[^\n]*SilentlyContinue`).MatchString(script) {
		t.Fatal("a delete that fails silently leaves a half-removed folder for Move-Item to nest into")
	}
}

func TestInstallScriptStopsWhenTheTargetSurvivesItsDelete(t *testing.T) {
	script := installScript(t)
	check := regexp.MustCompile(`if \(Test-Path \$path\) \{ throw`)
	if !check.MatchString(script) {
		t.Fatal("the script must refuse to Move-Item into a folder that is still there")
	}
	moveAt := strings.Index(script, "Move-Item $unpack $target")
	removeAt := strings.Index(script, "Remove-Folder $target")
	if removeAt < 0 || moveAt < removeAt {
		t.Fatal("the target must be removed (or the script stopped) before the move")
	}
}
