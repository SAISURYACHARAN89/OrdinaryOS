allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// reactive_ble_mobile 5.6 asks for compileSdkVersion 37, but the SDK now ships
// that platform only as "android-37.0", which the legacy setting can't find.
// It uses nothing past API 36, so compile it against 36 like the app.
subprojects {
    if (name == "reactive_ble_mobile") {
        afterEvaluate {
            extensions.getByName("android").withGroovyBuilder { "compileSdkVersion"(36) }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
