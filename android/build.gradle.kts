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

subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    plugins.withId("com.android.application") {
        val android = project.extensions.findByType(com.android.build.gradle.BaseExtension::class.java)
        android?.compileSdkVersion(35)
        android?.buildToolsVersion("34.0.0")
    }
    plugins.withId("com.android.library") {
        val android = project.extensions.findByType(com.android.build.gradle.BaseExtension::class.java)
        android?.compileSdkVersion(35)
        android?.buildToolsVersion("34.0.0")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
