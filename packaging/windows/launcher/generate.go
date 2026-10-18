// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

// Embeds the app icon so the shortcuts and Installed apps stop showing the generic one.
// No version is embedded: the launcher compares itself to the copy in each release byte for byte.
//go:generate go run github.com/tc-hib/go-winres@v0.3.3 simply --arch amd64 --manifest none --icon ../../../client/packages/app/windows/runner/resources/app_icon.ico --product-name slim-m --file-description slim-m
