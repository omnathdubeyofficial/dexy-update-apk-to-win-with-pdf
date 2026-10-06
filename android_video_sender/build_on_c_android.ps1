$srcDir = "C:\Users\omnat\OneDrive\Desktop\Dex Dev\Dex Official\Dexy Update APK To Win With PDF\android_video_sender"
$buildDir = "C:\dexy_temp_android_build"

if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir }
New-Item -ItemType Directory -Path $buildDir

# Use Robocopy for reliable recursive copy
robocopy $srcDir $buildDir /E /MT /R:1 /W:1 /XD .dart_tool build .idea

Set-Location $buildDir
flutter build apk --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$outputDir = "C:\Users\omnat\OneDrive\Desktop\Dex Dev\Dex Official\Dexy Update APK To Win With PDF\android_video_sender\build\app\outputs\flutter-apk"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force }
Copy-Item -Path "$buildDir\build\app\outputs\flutter-apk\app-release.apk" -Destination "$outputDir\app-release.apk" -Force
