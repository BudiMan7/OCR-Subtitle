#!/usr/bin/env bash
# Dijalankan oleh GitHub Actions setelah 'flutter create'. Memasang kode aplikasi ke proyek.
set -eu
mkdir -p lib
cp main.dart lib/main.dart

# ... sisa patch.sh (minSdk, R8, MainActivity, manifest, dst.)


if [ -d assets ]; then
  mkdir -p assets
  cp -r assets/. assets/
fi

if [ -f android/app/build.gradle.kts ]; then
  GRADLE=android/app/build.gradle.kts
  KTS=1
else
  GRADLE=android/app/build.gradle
  KTS=0
fi

# 1) minSdk 24 (dibutuhkan ML Kit)
sed -i 's/flutter\.minSdkVersion/24/' "$GRADLE"
echo "--- minSdk ---"; grep -n "minSdk" "$GRADLE" || true

# 2) Matikan R8/minify (R8 gagal dengan ML Kit)
if [ "$KTS" = "1" ]; then
  sed -i '/^[[:space:]]*release[[:space:]]*{/a\            isMinifyEnabled = false\n            isShrinkResources = false' "$GRADLE"
else
  sed -i '/^[[:space:]]*release[[:space:]]*{/a\            minifyEnabled false\n            shrinkResources false' "$GRADLE"
fi
grep -qE "isMinifyEnabled = false|minifyEnabled false" "$GRADLE" || { echo "GAGAL mematikan minify"; exit 1; }

# 3) Model OCR Jepang (opsional di app, harus ada sebagai dependensi)
if [ "$KTS" = "1" ]; then
  printf '\ndependencies {\n    implementation("com.google.mlkit:text-recognition-japanese:16.0.0")\n}\n' >> "$GRADLE"
else
  printf "\ndependencies {\n    implementation 'com.google.mlkit:text-recognition-japanese:16.0.0'\n}\n" >> "$GRADLE"
fi
echo "--- akhir $GRADLE ---"; tail -8 "$GRADLE"

# 4) MainActivity (+ OcrService) dengan package milik proyek
KT=$(find android/app/src/main -name MainActivity.kt | head -n1)
if [ -z "$KT" ]; then
  echo "MainActivity.kt tidak ditemukan"; find android/app/src/main -type f | head -30; exit 1
fi
PKG=$(grep -m1 '^package ' "$KT")
[ -n "$PKG" ] || { echo "GAGAL: package tidak ditemukan"; exit 1; }
{ echo "$PKG"; tail -n +2 MainActivity.kt; } > "$KT.new"
mv "$KT.new" "$KT"
grep -q '"pick" ->' "$KT" || { echo "GAGAL: MainActivity tidak terpasang"; exit 1; }
grep -q 'class OcrService' "$KT" || { echo "GAGAL: OcrService tidak terpasang"; exit 1; }

# 5) Manifest: nama app, izin, dan service latar depan
MAN=android/app/src/main/AndroidManifest.xml
sed -i 's/android:label="[^"]*"/android:label="Hardsub OCR"/' "$MAN"
sed -i 's#<application#<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>\n    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n    <application#' "$MAN"
sed -i 's#</application>#    <service android:name=".OcrService" android:exported="false" android:foregroundServiceType="dataSync"/>\n    </application>#' "$MAN"
grep -q 'OcrService' "$MAN" || { echo "GAGAL: manifest"; exit 1; }
echo "--- manifest ---"; cat "$MAN"
echo "patch selesai: $KT ($PKG)"
