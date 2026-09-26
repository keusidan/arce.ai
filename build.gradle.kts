// Plugins are declared in each module instead of here with `apply false`.
// Declaring the Android plugin at the root would make every build resolve it from
// Google Maven, even the :core-only builds that settings.gradle.kts allows without an SDK.
