pluginManagement {
    repositories {
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        maven("https://repo1.maven.org/maven2/")
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories { maven("https://maven-central.storage-download.googleapis.com/maven2/")
        maven("https://repo1.maven.org/maven2/") }
}
rootProject.name = "kotlin-prober-runner"
