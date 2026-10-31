// Runs the ORIGINAL OpenCfMoto Android EasyConnProber (copied verbatim into upstream/) on a desktop JVM.
//  - stubs/java + aosp-json : "stubs" source set — hand-written Android framework stand-ins (+ generated R/BuildConfig) and the
//                              unmodified AOSP org.json sources (aosp-json/, see aosp-json/SOURCE.txt)
//  - upstream   : verbatim copies of app/src/main/java/dev/zanderp/opencfmoto/*.kt (see upstream/SHA256SUMS)
//  - appstubs   : thin stand-ins for Android-only upstream app classes (BikeWifi, AaCompositor, …)
//  - runner     : harness main (prober lifecycle, AndroidAutoService watchdog re-implementation, touch sink)
plugins {
    kotlin("jvm") version "2.0.21"
    application
}

sourceSets {
    create("stubs") {
        java.setSrcDirs(listOf("stubs/java", "aosp-json"))
    }
    main {
        java.setSrcDirs(emptyList<String>())
        kotlin.setSrcDirs(listOf("upstream", "appstubs", "runner"))
        compileClasspath += sourceSets["stubs"].output
        runtimeClasspath += sourceSets["stubs"].output
    }
}

// org.json = the AOSP Android 14 libcore/json sources in aosp-json/ (insertion-ordered LinkedHashMap
// JSONObject, writes "\/"), compiled into the stubs source set. NOT the desktop JSON-java (org.json:json),
// whose JSONObject is a HashMap and does not escape '/', and NOT com.vaadin.external.google:android-json
// (a 2013 AOSP snapshot that still used HashMap). Keeps CLIENT_INFO / CHECK_SN bytes identical to Android.

java { toolchain { languageVersion.set(JavaLanguageVersion.of(21)) } }
kotlin { jvmToolchain(21) }
tasks.withType<JavaCompile>().configureEach { options.encoding = "UTF-8" }

application {
    mainClass.set("harness.MainKt")
    applicationDefaultJvmArgs = listOf("-Dstdout.encoding=UTF-8", "-Dstderr.encoding=UTF-8", "-Dfile.encoding=UTF-8")
}

// Ship the stubs classes inside the distribution's runtime classpath too.
tasks.named<Jar>("jar") { from(sourceSets["stubs"].output) }
