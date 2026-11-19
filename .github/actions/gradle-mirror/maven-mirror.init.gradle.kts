// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

// Google's mirror of Maven Central goes first in every repository list; see action.yml for why.

import org.gradle.api.initialization.resolve.RepositoriesMode

val mirror = "https://maven-central.storage-download.googleapis.com/maven2/"

fun RepositoryHandler.preferMirror() {
    val first = maven {
        name = "MavenCentralMirror"
        url = uri(mirror)
        // Marker POMs and Google's own artifacts differ from Central's copies, and dependency verification pins the originals.
        content {
            excludeModuleByRegex(".*", ".*\\.gradle\\.plugin")
            excludeGroupByRegex("com\\.android(\\..*)?")
            excludeGroupByRegex("androidx(\\..*)?")
            excludeGroupByRegex("com\\.google\\.(android|firebase|gms|mlkit)(\\..*)?")
        }
    }
    remove(first)
    addFirst(first)
}

gradle.beforeSettings {
    pluginManagement.repositories.preferMirror()
    dependencyResolutionManagement.repositories.preferMirror()
}

gradle.settingsEvaluated {
    // A build that named no plugin repositories got Gradle's implicit portal; the mirror alone would drop it.
    if (pluginManagement.repositories.toList().all { it.name == "MavenCentralMirror" }) {
        pluginManagement.repositories.gradlePluginPortal()
    }
    // flutter_tools/gradle fails any build whose projects declare repositories, so those keep the settings list.
    if (dependencyResolutionManagement.repositoriesMode.get() != RepositoriesMode.FAIL_ON_PROJECT_REPOS) {
        gradle.allprojects {
            buildscript.repositories.preferMirror()
            repositories.preferMirror()
        }
    }
}
