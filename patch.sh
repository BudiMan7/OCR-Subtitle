#!/usr/bin/env bash
# Dijalankan oleh GitHub Actions setelah 'flutter create'. Memasang kode aplikasi ke proyek.
set -eu
mkdir -p lib
cp main.dart lib/main.dart

# minSdk 24 (dibutuhkan ML Kit)
if [ -f android/app/build.gradle.kts ]; then
  GRADLE=android/app/build.gradle.kts
else
  GRADLE=android/app/build.gradle
fi
sed -i 's/flutter\.minSdkVersion/24/' "$GRADLE"
echo "--- baris minSdk di $GRADLE ---"
grep -n "minSdk" "$GRADLE" || true

# Matikan R8/minify (R8 gagal dengan ML Kit). APK sedikit lebih besar tapi build aman.
if [ "$GRADLE" = "android/app/build.gradle.kts" ]; then
  sed -i '/^[[:space:]]*release[[:space:]]*{/a\            isMinifyEnabled = false\n            isShrinkResources = false' "$GRADLE"
else
  sed -i '/^[[:space:]]*release[[:space:]]*{/a\            minifyEnabled false\n            shrinkResources false' "$GRADLE"
fi
echo "--- blok release ---"
grep -n -A6 "release" "$GRADLE" || true
if ! grep -qE "isMinifyEnabled = false|minifyEnabled false" "$GRADLE"; then
  echo "GAGAL mematikan minify"; exit 1
fi

# Ganti MainActivity dengan versi kita, pertahankan baris package bawaan
KT=$(find android/app/src/main -name MainActivity.kt | head -n1)
if [ -z "$KT" ]; then
  echo "MainActivity.kt tidak ditemukan"; find android/app/src/main -type f | head -30; exit 1
fi
PKG=$(grep -m1 '^package ' "$KT")
