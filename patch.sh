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

# Ganti MainActivity dengan versi kita, pertahankan baris package bawaan
KT=$(find android/app/src/main -name MainActivity.kt | head -n1)
if [ -z "$KT" ]; then
  echo "MainActivity.kt tidak ditemukan"; find android/app/src/main -type f | head -30; exit 1
fi
PKG=$(grep -m1 '^package ' "$KT")
{ echo "$PKG"; tail -n +2 MainActivity.kt; } > "$KT.new"
mv "$KT.new" "$KT"

# Nama aplikasi
sed -i 's/android:label="[^"]*"/android:label="Hardsub OCR"/' android/app/src/main/AndroidManifest.xml
echo "patch selesai: $KT ($PKG)"
