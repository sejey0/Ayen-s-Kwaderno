# Flutter Wrapper & Plugins
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Flutter Deferred Components / Play Core (Suppress missing optional play core dependencies)
-dontwarn com.google.android.play.core.**
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# AndroidX WorkManager & Room (Fixes "Failed to create an instance of androidx.work.impl.WorkDatabase")
-keep class androidx.work.** { *; }
-keep class * extends androidx.work.impl.WorkDatabase { *; }
-keepclassmembers class * extends androidx.work.impl.WorkDatabase {
    public <init>(...);
}
-keep class * extends androidx.work.ListenableWorker {
    public <init>(...);
}
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
    *;
}
-keep class * extends androidx.room.RoomDatabase { *; }
-keepclassmembers class * extends androidx.room.RoomDatabase {
    public <init>(...);
    *;
}
-keep class * extends androidx.room.Entity { *; }
-keep class * extends androidx.room.Dao { *; }
-dontwarn androidx.work.**
-dontwarn androidx.room.**

# AndroidX Startup Initializer
-keep class androidx.startup.** { *; }
-keep class * extends androidx.startup.Initializer { *; }
-keepclassmembers class * extends androidx.startup.Initializer {
    public <init>();
}
-dontwarn androidx.startup.**

# Google ML Kit
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# Syncfusion PDF Viewer & Platform Interface
-keep class com.syncfusion.** { *; }
-dontwarn com.syncfusion.**

# Networking & Coroutines
-dontwarn okio.**
-dontwarn okhttp3.**
-dontwarn io.ktor.**
-dontwarn kotlinx.coroutines.**
-dontwarn sun.misc.**
