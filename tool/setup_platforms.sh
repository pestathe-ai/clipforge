#!/usr/bin/env bash
# Genera le cartelle android/ e ios/ e imposta versioni minime e permessi
# richiesti da ffmpeg_kit_flutter_new, file_picker e gal.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create --project-name clipforge --org dev.clipforge --platforms=android,ios .
rm -f test/widget_test.dart  # il test di esempio generato si riferisce a MyApp

# Android: minSdk 24 richiesto da FFmpegKit.
GRADLE=android/app/build.gradle.kts
[ -f "$GRADLE" ] || GRADLE=android/app/build.gradle
sed -i.bak -E 's/minSdk *= *flutter\.minSdkVersion/minSdk = 24/; s/minSdkVersion flutter\.minSdkVersion/minSdkVersion 24/' "$GRADLE"
rm -f "$GRADLE.bak"

# Android: permesso microfono per la voce fuori campo.
MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q RECORD_AUDIO "$MANIFEST"; then
  sed -i.bak 's#<application#<uses-permission android:name="android.permission.RECORD_AUDIO"/>\n    <application#' "$MANIFEST"
  rm -f "$MANIFEST.bak"
fi

# Android: modello di ritaglio oggetti di ML Kit (scaricato da Google Play Services).
if ! grep -q subject_segment "$MANIFEST"; then
  sed -i.bak 's#</application>#    <meta-data android:name="com.google.mlkit.vision.DEPENDENCIES" android:value="subject_segment" />\n    </application>#' "$MANIFEST"
  rm -f "$MANIFEST.bak"
fi

# iOS: target minimo 15.6 (ML Kit) e descrizioni dei permessi foto.
PLIST=ios/Runner/Info.plist
add_key() {
  /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST"
}
if [ -x /usr/libexec/PlistBuddy ]; then
  add_key NSPhotoLibraryUsageDescription "ClipForge usa i tuoi video per montarli."
  add_key NSPhotoLibraryAddUsageDescription "ClipForge salva i video esportati nella galleria."
  add_key NSMicrophoneUsageDescription "ClipForge registra la voce fuori campo."
  sed -i '' -E "s/# platform :ios, '[0-9.]+'/platform :ios, '15.6'/" ios/Podfile 2>/dev/null || true
else
  echo "Non sei su macOS: aggiungi a mano a $PLIST le chiavi"
  echo "NSPhotoLibraryUsageDescription e NSPhotoLibraryAddUsageDescription."
fi

flutter pub get
echo "Fatto. Avvia con: flutter run"
