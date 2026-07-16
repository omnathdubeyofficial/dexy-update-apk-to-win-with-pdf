$srcDir = "c:\Users\omnat\OneDrive\Desktop\DEX\DEX\Dexy Update APK To Win With PDF\windows_video_receiver"
$buildDir = "C:\dexy_win_build"

if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir }
New-Item -ItemType Directory -Path $buildDir

# Use Robocopy for reliable recursive copy
robocopy $srcDir $buildDir /E /MT /R:1 /W:1 /XD .dart_tool build .idea windows\flutter\ephemeral

Set-Location $buildDir
flutter pub get
flutter build windows --release

$outputDir = "c:\Users\omnat\OneDrive\Desktop\DEX\DEX\Dexy Update APK To Win With PDF\windows_video_receiver\build\windows\x64\runner\Release"
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force }
Copy-Item -Path "$buildDir\build\windows\x64\runner\Release\*" -Destination $outputDir -Recurse -Force

Write-Host "" -ForegroundColor Green
Write-Host "BUILD COMPLETE! Output: $outputDir" -ForegroundColor Green
