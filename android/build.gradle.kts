import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

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

// flutter_js 0.8.7 targets Kotlin/JVM 1.8, while AGP 9 defaults its Java
// compile task to 11. Keep those tasks aligned for this dependency only.
subprojects {
    if (name == "flutter_js") {
        afterEvaluate {
            tasks.withType<KotlinCompile>().configureEach {
                compilerOptions.jvmTarget.set(
                    org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11,
                )
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
