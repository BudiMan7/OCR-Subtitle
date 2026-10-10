#!/usr/bin/env bash
# Dijalankan oleh GitHub Actions setelah 'flutter create'. Memasang kode aplikasi ke proyek.
set -euo pipefail
mkdir -p lib
cp main.dart lib/main.dart

# minSdk 24 (dibutuhkan ML Kit)
GRADLE=$(ls android/app/build.gradle.kts android/app/build.gradle 2>/dev/null | head -n1)
sed -i 's/flutter\.minSdkVersion/24/' "$GRADLE"

# Ganti MainActivity dengan versi kita, pertahankan baris package bawaan
KT=$(find android/app/src/main -name MainActivity.kt | head -n1)
PKG=$(grep -m1 '^package ' "$KT")
{ echo "$PKG"; tail -n +2 MainActivity.kt; } > "$KT.new"
mv "$KT.new" "$KT"

# Nama aplikasi
sed -i 's/android:label="[^"]*"/android:label="Hardsub OCR"/' android/app/src/main/AndroidManifest.xml
echo "patch selesai: $KT"
