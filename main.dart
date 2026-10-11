import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

// =====================================================================
//  HARDSUB OCR → SRT / ASS  +  Analisis Kamus
// =====================================================================

const double kChangeFrac = 0.0015;
const double kMinTextFrac = 0.001;
const double kSim = 0.85;
const double kMaxDropoutSec = 0.6;
const double kMinDuration = 0.7;
const int kSaveEvery = 100;

/// Watermark yang selalu muncul. Dibandingkan secara fuzzy.
const List<String> kWatermarkKeys = [
  'rajanime',
  'rajanimecom',
];

/// Nama karakter / istilah yang TIDAK boleh dikoreksi kamus.
const Set<String> kProtectedWords = {
  'ilun', 'phuzeron', 'redof', 'hyss', 'gamillas', 'yamato',
  'ghader', 'thalan', 'abelt', 'dessler', 'kodai', 'mori',
};

const MethodChannel _ch = MethodChannel('hardsub/native');

// =====================================================================
//  KAMUS
// =====================================================================
Set<String> kKamus = {};
Map<int, List<String>> kKamusByLen = {};
bool kKamusReady = false;

Future<void> loadKamus() async {
  if (kKamusReady) return;
  try {
    final s = await rootBundle.loadString('assets/kamus_id.txt');
    final words = s
        .split('\n')
        .map((l) => l.trim().toLowerCase())
        .where((l) => l.isNotEmpty)
        .where((l) => !l.startsWith('#'))
        .where((l) => !l.startsWith('.'))
        // hanya huruf kecil dan tanda hubung di tengah, panjang >= 3
        .where((l) => RegExp(r'^[a-z][a-z-]*[a-z]$').hasMatch(l))
        .where((l) => l.length >= 3)
        .toSet();
    kKamus = words;
    kKamusByLen = {};
    for (final w in words) {
      kKamusByLen.putIfAbsent(w.length, () => []).add(w);
    }
    kKamusReady = true;
  } catch (_) {
    // file tidak ada → aplikasi tetap jalan tanpa kamus
  }
}

// ----------------------- util waktu -----------------------
String fmtSrt(double t) {
  var ms = (math.max(0.0, t) * 1000).round();
  final h = ms ~/ 3600000;
  ms %= 3600000;
  final m = ms ~/ 60000;
  ms %= 60000;
  final s = ms ~/ 1000;
  ms %= 1000;
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(h)}:${p(m)}:${p(s)},${p(ms, 3)}';
}

double parseSrt(String s) {
  final m = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?$').firstMatch(s.trim());
  if (m == null) throw const FormatException('Format waktu salah. Contoh benar: 00:01:23,500');
  final h = int.parse(m.group(1) ?? '0');
  final mi = int.parse(m.group(2)!);
  final se = int.parse(m.group(3)!);
  final ms = int.parse((m.group(4) ?? '0').padRight(3, '0'));
  return h * 3600 + mi * 60 + se + ms / 1000;
}

String fmtClock(double t) {
  final s = t.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String p(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${p(m)}:${p(sec)}' : '${p(m)}:${p(sec)}';
}

double? parseClock(String s) {
  final m = RegExp(r'^\s*(?:(\d+):)?(\d{1,3}):(\d{1,2})\s*$').firstMatch(s);
  if (m == null) return null;
  final h = int.parse(m.group(1) ?? '0');
  final mi = int.parse(m.group(2)!);
  final se = int.parse(m.group(3)!);
  if (se >= 60) return null;
  return (h * 3600 + mi * 60 + se).toDouble();
}

String fmtDur(int sec) => sec >= 60 ? '${sec ~/ 60} mnt ${sec % 60} dtk' : '$sec dtk';

String fmtAss(double t) {
  var cs = (math.max(0.0, t) * 100).round();
  final h = cs ~/ 360000;
  cs %= 360000;
  final m = cs ~/ 6000;
  cs %= 6000;
  final s = cs ~/ 100;
  cs %= 100;
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '$h:${p(m)}:${p(s)}.${p(cs)}';
}

// ----------------------- util teks -----------------------
const String _latinExt = r'\u00C0-\u024F';
const String _cjkCore = r'\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff';
final RegExp _reLetter = RegExp('[A-Za-z$_latinExt$_cjkCore]');
final RegExp _reNormDrop = RegExp('[^a-z0-9$_cjkCore]+');
final RegExp _reAlnum = RegExp('[A-Za-z0-9$_latinExt$_cjkCore]');
final RegExp _cjk = RegExp(r'[\u3000-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef\uac00-\ud7af]');

int letterCount(String t) => _reLetter.allMatches(t).length;
String norm(String t) => t.toLowerCase().replaceAll(_reNormDrop, '');
bool hasCjk(String t) => _cjk.hasMatch(t);

String cleanText(String t, int mode) {
  final out = <String>[];
  for (var line in t.split('\n')) {
    final nCjk = _cjk.allMatches(line).length;
    if (mode == 0) {
      if (nCjk > 0) {
        final latin = RegExp(r'[A-Za-z]').allMatches(line).length;
        if (latin >= 3 * nCjk && latin >= 3) {
          line = line.replaceAll(_cjk, ' ');
        } else {
          continue;
        }
      }
    } else if (mode == 1) {
      if (nCjk == 0) continue;
    }
    line = line.replaceAll(RegExp(r'\s+'), ' ').trim();
    final compact = line.replaceAll(' ', '');
    if (compact.isEmpty) continue;
    final alnum = _reAlnum.allMatches(compact).length;
    if (alnum >= 1 && alnum / compact.length >= 0.6) out.add(line);
  }
  return out.join('\n');
}

// ----------------------- watermark -----------------------
bool looksLikeWatermark(String text) {
  final n = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (n.length < 4) return false;
  if (RegExp(r'[a-z0-9]{3,}\.(?:com|net|tv|org|xyz|info|biz|co)', caseSensitive: false).hasMatch(text)) {
    return true;
  }
  for (final k in kWatermarkKeys) {
    if (n.contains(k)) return true;
    final win = k.length;
    if (n.length < win) {
      if (simRatio(n, k) >= 0.75) return true;
      continue;
    }
    var best = 0.0;
    for (var i = 0; i + win <= n.length; i++) {
      final r = simRatio(n.substring(i, i + win), k);
      if (r > best) best = r;
      if (best >= 0.85) break;
    }
    if (best >= 0.80) return true;
  }
  return false;
}

String stripWatermark(String text) {
  var s = text;
  s = s.replaceAll(
    RegExp(r'\b[a-z0-9@\-]{3,}\.(?:com|net|tv|org|xyz|info|biz|co)\b', caseSensitive: false),
    ' ',
  );
  s = s.replaceAll(
    RegExp(r'[a-z]{3,}(?:com|net|tv|org|xyz)\b', caseSensitive: false),
    ' ',
  );
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<Sub> dropWatermarks(List<Sub> subs, double videoDurationSec, {double frac = 0.7}) {
  if (videoDurationSec <= 0 || subs.isEmpty) return subs;
  final dur = <String, double>{};
  for (final s in subs) {
    final key = norm(s.text).replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (key.isEmpty) continue;
    dur[key] = (dur[key] ?? 0) + (s.end - s.start);
  }
  final threshold = videoDurationSec * frac;
  final blacklist = dur.entries.where((e) => e.value > threshold).map((e) => e.key).toSet();
  if (blacklist.isEmpty) return subs;
  return subs.where((s) {
    final key = norm(s.text).replaceAll(RegExp(r'[^a-z0-9]'), '');
    return !blacklist.contains(key);
  }).toList();
}

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[b.length];
}

double simRatio(String a, String b) {
  final m = math.max(a.length, b.length);
  if (m == 0) return 1.0;
  return 1.0 - _lev(a, b) / m;
}

bool similar(String a, String b) {
  if (a == b) return true;
  final minLen = (hasCjk(a) || hasCjk(b)) ? 3 : 6;
  if (math.min(a.length, b.length) < minLen) return false;
  return simRatio(a, b) >= kSim;
}

// ----------------------- model -----------------------
class Sample {
  double t;
  String text;
  int zone;
  Sample(this.t, this.text, [this.zone = 0]);
  Map<String, dynamic> toJson() => {'t': t, 'text': text, 'z': zone};
  factory Sample.fromJson(Map<String, dynamic> j) => Sample(
        (j['t'] as num).toDouble(),
        j['text'] as String,
        (j['z'] as num?)?.toInt() ?? 0,
      );
}

class Sub {
  double start;
  double end;
  String text;
  List<String> warn;
  int zone;
  Sub(this.start, this.end, this.text, this.warn, {this.zone = 0});
  Map<String, dynamic> toJson() =>
      {'start': start, 'end': end, 'text': text, 'warn': warn, 'zone': zone};
  factory Sub.fromJson(Map<String, dynamic> j) => Sub(
        (j['start'] as num).toDouble(),
        (j['end'] as num).toDouble(),
        j['text'] as String,
        (j['warn'] as List).map((e) => e.toString()).toList(),
        zone: (j['zone'] as num?)?.toInt() ?? 0,
      );
}

class _G {
  double first;
  double last;
  String lastN;
  final List<String> texts = [];
  final List<String> ns = [];
  _G(this.first, String text, String n)
      : last = first,
        lastN = n {
    texts.add(text);
    ns.add(n);
  }
  void add(double t, String text, String n) {
    texts.add(text);
    ns.add(n);
    last = t;
    lastN = n;
  }
}

class _R {
  double first;
  double last;
  int count;
  String n;
  String text;
  _R(this.first, this.last, this.count, this.n, this.text);
}

class _Ln {
  final String text;
  final Rect box;
  _Ln(this.text, this.box);
}

// ----------------------- merge -----------------------
List<Sub> _mergeOneZone(List<Sample> samples, double interval, int zone) {
  const eps = 1e-6;
  final groups = <_G>[];
  _G? cur;
  for (final s in samples) {
    final n = letterCount(s.text) >= 2 ? norm(s.text) : '';
    if (n.isEmpty) continue;
    final c = cur;
    if (c != null) {
      final gap = s.t - c.last;
      final longEnough = n.length >= (hasCjk(n) ? 3 : 6);
      final gapOk = gap <= interval + eps || (gap <= interval + kMaxDropoutSec + eps && longEnough);
      if (gapOk && similar(n, c.lastN)) {
        c.add(s.t, s.text, n);
        continue;
      }
      groups.add(c);
    }
    cur = _G(s.t, s.text, n);
  }
  if (cur != null) groups.add(cur);

  final recs = <_R>[];
  for (final g in groups) {
    final cnt = <String, int>{};
    for (final n in g.ns) {
      cnt[n] = (cnt[n] ?? 0) + 1;
    }
    var bestN = g.ns.first;
    for (final e in cnt.entries) {
      if (e.value > (cnt[bestN] ?? 0)) bestN = e.key;
    }
    final tc = <String, int>{};
    for (var i = 0; i < g.ns.length; i++) {
      if (g.ns[i] == bestN) tc[g.texts[i]] = (tc[g.texts[i]] ?? 0) + 1;
    }
    var bestT = tc.keys.first;
    for (final e in tc.entries) {
      final b = tc[bestT] ?? 0;
      if (e.value > b || (e.value == b && e.key.length > bestT.length)) bestT = e.key;
    }
    recs.add(_R(g.first, g.last, g.ns.length, bestN, bestT));
  }

  final absorbed = <int>{};
  for (var i = 0; i < recs.length; i++) {
    final r = recs[i];
    if (r.count != 1 || interval > 0.6) continue;
    int? bestJ;
    var bestRatio = 0.55;
    for (final j in [i - 1, i + 1]) {
      if (j < 0 || j >= recs.length || absorbed.contains(j) || recs[j].count < 2) continue;
      final gap = j < i ? r.first - recs[j].last : recs[j].first - r.last;
      final ratio = simRatio(r.n, recs[j].n);
      if (gap <= interval + eps && ratio >= bestRatio) {
        bestJ = j;
        bestRatio = ratio;
      }
    }
    if (bestJ != null) {
      recs[bestJ].first = math.min(recs[bestJ].first, r.first);
      recs[bestJ].last = math.max(recs[bestJ].last, r.last);
      absorbed.add(i);
    }
  }

  final subs = <Sub>[];
  for (var i = 0; i < recs.length; i++) {
    if (absorbed.contains(i)) continue;
    final r = recs[i];
    final letters = letterCount(r.text);
    final compact = r.text.replaceAll(RegExp(r'\s'), '').length;
    final ratio = compact == 0 ? 0.0 : letters / compact;
    if (r.count == 1 && (letters < 3 || ratio < 0.7)) continue;
    final warn = <String>[];
    if (r.count == 1) warn.add('hanya terbaca 1 kali');
    if (letters < 4) warn.add('teks sangat pendek');
    if (ratio < 0.7) warn.add('banyak karakter aneh');
    subs.add(Sub(
      math.max(0.0, r.first - interval / 2),
      r.last + interval / 2,
      r.text,
      warn,
      zone: zone,
    ));
  }
  for (final s in subs) {
    if (s.end - s.start < kMinDuration) {
      s.end = s.start + kMinDuration;
      s.warn.add('durasi sangat pendek');
    }
    if (s.end - s.start > 8) s.warn.add('durasi panjang (>8 dtk)');
  }
  for (var i = 0; i + 1 < subs.length; i++) {
    if (subs[i].end > subs[i + 1].start) {
      subs[i].end = math.max(subs[i].start + 0.1, subs[i + 1].start - 0.001);
    }
  }
  return subs;
}

List<Sub> mergeSamples(List<Sample> samples, double interval) {
  final byZone = <int, List<Sample>>{};
  for (final s in samples) {
    byZone.putIfAbsent(s.zone, () => []).add(s);
  }
  final all = <Sub>[];
  for (final e in byZone.entries) {
    all.addAll(_mergeOneZone(e.value, interval, e.key));
  }
  all.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.zone.compareTo(b.zone);
  });
  for (var i = 0; i + 1 < all.length; i++) {
    if (all[i].zone == all[i + 1].zone && all[i].end > all[i + 1].start) {
      all[i].end = math.max(all[i].start + 0.1, all[i + 1].start - 0.001);
    }
  }
  return all;
}

String buildSrt(List<Sub> subs) {
  final sorted = [...subs]..sort((a, b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : a.zone.compareTo(b.zone);
    });
  final b = StringBuffer();
  var n = 0;
  for (final s in sorted) {
    final text = s.text.trim();
    if (text.isEmpty) continue;
    n++;
    b.write('$n\r\n${fmtSrt(s.start)} --> ${fmtSrt(s.end)}\r\n${text.replaceAll('\n', '\r\n')}\r\n\r\n');
  }
  return b.toString();
}

// ----------------------- ASS -----------------------
List<String> _wrapText(String text, int maxChars, int maxLines) {
  final out = <String>[];
  for (var raw in text.split('\n')) {
    raw = raw.trim();
    if (raw.isEmpty) continue;
    final words = raw.split(RegExp(r'\s+'));
    var cur = '';
    for (final w in words) {
      var word = w;
      while (word.length > maxChars) {
        if (cur.isNotEmpty) {
          out.add(cur);
          cur = '';
          if (out.length >= maxLines) break;
        }
        out.add(word.substring(0, maxChars));
        word = word.substring(maxChars);
        if (out.length >= maxLines) break;
      }
      if (out.length >= maxLines) break;
      if (cur.isEmpty) {
        cur = word;
      } else if ((cur.length + 1 + word.length) <= maxChars) {
        cur = '$cur $word';
      } else {
        out.add(cur);
        cur = word;
        if (out.length >= maxLines) break;
      }
    }
    if (out.length >= maxLines) break;
    if (cur.isNotEmpty) out.add(cur);
    if (out.length >= maxLines) break;
  }
  return out.take(maxLines).toList();
}

String buildAss(List<Sub> subs, int vw, int vh, {int fontSize = 48}) {
  final sorted = [...subs]..sort((a, b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : a.zone.compareTo(b.zone);
    });

  final marginL = (vw * 0.06).round();
  final marginR = (vw * 0.06).round();
  final marginVTop = (vh * 0.04).round();
  final marginVBottom = (vh * 0.06).round();

  final usableW = vw - marginL - marginR;
  final maxChars = math.max(12, (usableW / (fontSize * 0.5)).floor());
  const maxLinesPerZone = 2;

  final b = StringBuffer()
    ..writeln('[Script Info]')
    ..writeln('ScriptType: v4.00+')
    ..writeln('PlayResX: $vw')
    ..writeln('PlayResY: $vh')
    ..writeln('WrapStyle: 0')
    ..writeln('ScaledBorderAndShadow: yes')
    ..writeln()
    ..writeln('[V4+ Styles]')
    ..writeln('Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
        'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
        'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
        'Alignment, MarginL, MarginR, MarginV, Encoding');

  b.writeln('Style: Dialog,Arial,$fontSize,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,'
      '0,0,0,0,100,100,0,0,1,2,1,2,$marginL,$marginR,$marginVBottom,1');
  b.writeln('Style: Label,Arial,$fontSize,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,'
      '0,0,0,0,100,100,0,0,1,2,1,2,$marginL,$marginR,${marginVBottom + (fontSize * maxLinesPerZone * 1.2).round()},1');
  b.writeln('Style: Top,Arial,$fontSize,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,'
      '0,0,0,0,100,100,0,0,1,2,1,8,$marginL,$marginR,$marginVTop,1');

  b
    ..writeln()
    ..writeln('[Events]')
    ..writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text');

  var layer = 0;
  for (final s in sorted) {
    final lines = _wrapText(s.text, maxChars, maxLinesPerZone);
    if (lines.isEmpty) continue;
    final text = lines.join(r'\N');
    final style = s.zone == 0 ? 'Top' : (s.zone == 1 ? 'Dialog' : 'Label');
    layer = (layer + 1) % 3;
    b.writeln('Dialogue: $layer,${fmtAss(s.start)},${fmtAss(s.end)},$style,,0,0,0,,$text');
  }
  return b.toString();
}

// ----------------------- koreksi frekuensi -----------------------
final RegExp _wordRe = RegExp(r'[A-Za-z0-9]+');

String _canon(String w) {
  var s = w.toLowerCase().replaceAll('rn', 'm').replaceAll('vv', 'w');
  s = s.replaceAll(RegExp(r'[l1]'), 'i').replaceAll('0', 'o');
  return s;
}

String _matchCase(String orig, String fixed) {
  if (orig.length > 1 && orig == orig.toUpperCase()) return fixed.toUpperCase();
  if (orig.isNotEmpty && orig[0] == orig[0].toUpperCase() && orig[0] != orig[0].toLowerCase()) {
    return fixed[0].toUpperCase() + fixed.substring(1);
  }
  return fixed;
}

Map<String, String> buildFixes(List<Sub> subs) {
  final freq = <String, int>{};
  for (final s in subs) {
    for (final m in _wordRe.allMatches(s.text)) {
      final w = m.group(0)!.toLowerCase();
      freq[w] = (freq[w] ?? 0) + 1;
    }
  }
  final best = <String, String>{};
  for (final e in freq.entries) {
    if (e.value >= 3 && e.key.length >= 3) {
      final c = _canon(e.key);
      final cur = best[c];
      if (cur == null || (freq[cur] ?? 0) < e.value) best[c] = e.key;
    }
  }
  final fixes = <String, String>{};
  for (final e in freq.entries) {
    if (e.key.length < 3 || e.value > 2) continue;
    final b = best[_canon(e.key)];
    if (b != null && b != e.key && (freq[b] ?? 0) >= e.value * 3) fixes[e.key] = b;
  }
  return fixes;
}

// =====================================================================
//  ANALISIS KAMUS
// =====================================================================
class UsulanKoreksi {
  final String asli;
  final String usul;
  final String alasan;
  bool dicentang;
  UsulanKoreksi(this.asli, this.usul, this.alasan, {this.dicentang = true});
}

/// Apakah kata ini dilindungi (nama karakter/istilah)?
bool _isProtected(String w) => kProtectedWords.contains(w.toLowerCase());

/// Apakah kata ini ada di kamus?
bool _inKamus(String w) => kKamus.contains(w.toLowerCase());

/// Berisi angka?
bool _hasDigit(String w) => RegExp(r'[0-9]').hasMatch(w);

/// Perbaiki angka → huruf: d1 → di, m0kan → makan
String _fixDigits(String w) {
  return w
      .replaceAll('0', 'o')
      .replaceAll('1', 'l')
      .replaceAll('3', 'e')
      .replaceAll('4', 'a')
      .replaceAll('5', 's')
      .replaceAll('7', 't');
}

/// Punya huruf besar di tengah? (indikasi nama)
bool _hasMidUpper(String w) {
  if (w.length < 2) return false;
  return w.substring(1).contains(RegExp(r'[A-Z]'));
}

/// Cari kandidat terdekat di kamus. Return null kalau tidak ada.
String? _cariKandidat(String w) {
  final lower = w.toLowerCase();
  var bestDist = 3;
  String? best;
  for (var len = lower.length - 2; len <= lower.length + 2; len++) {
    final list = kKamusByLen[len];
    if (list == null) continue;
    for (final k in list) {
      final d = _lev(lower, k);
      if (d < bestDist) {
        bestDist = d;
        best = k;
        if (d == 1) break;
      }
    }
    if (bestDist == 1) break;
  }
  if (best == null) return null;
  if (bestDist > 2) return null;
  return best;
}

/// Analisis semua subtitle. Mengembalikan daftar usulan koreksi.
List<UsulanKoreksi> analyzeText(List<Sub> subs) {
  if (kKamus.isEmpty) return [];

  // kumpulkan semua kata unik
  final kataSet = <String>{};
  for (final s in subs) {
    for (final m in _wordRe.allMatches(s.text)) {
      kataSet.add(m.group(0)!);
    }
  }

  final usulan = <UsulanKoreksi>[];

  for (final w in kataSet) {
    // aturan 1: kata dilindungi → skip
    if (_isProtected(w)) continue;
    // kata terlalu pendek → skip
    if (w.length < 3) continue;

    final lower = w.toLowerCase();

    // sudah ada di kamus → skip
    if (_inKamus(lower)) continue;

    // nama (huruf besar di tengah) → skip, biarkan
    if (_hasMidUpper(w)) continue;

    // aturan 2: ada angka → coba perbaiki angka jadi huruf dulu
    if (_hasDigit(w)) {
      final fixed = _fixDigits(lower);
      if (kKamus.contains(fixed)) {
        usulan.add(UsulanKoreksi(w, _matchCase(w, fixed), 'angka → huruf'));
        continue;
      }
    }

    // aturan 3: cari kandidat terdekat
    final kand = _cariKandidat(lower);
    if (kand != null) {
      usulan.add(UsulanKoreksi(w, _matchCase(w, kand), 'mirip kata di kamus'));
    }
    // kalau tidak ada kandidat → biarkan (mungkin nama/istilah asing)
  }

  usulan.sort((a, b) => a.asli.toLowerCase().compareTo(b.asli.toLowerCase()));
  return usulan;
}

// =====================================================================
//  APLIKASI
// =====================================================================
void main() => runApp(const HardsubApp());

class HardsubApp extends StatelessWidget {
  const HardsubApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hardsub OCR',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final TextRecognizer _rec = TextRecognizer(script: TextRecognitionScript.latin);
  TextRecognizer? _recJp;
  TextRecognizer get _jp => _recJp ??= TextRecognizer(script: TextRecognitionScript.japanese);
  final TextEditingController _timeCtl = TextEditingController(text: '00:30');

  String? uri;
  String name = '';
  int durMs = 0;
  int vw = 0, vh = 0;
  double previewT = 30;
  Uint8List? previewBytes;
  double previewAspect = 16 / 9;
  String? lastUri;
  String lastName = '';

  RangeValues yR = const RangeValues(0.72, 0.92);
  RangeValues xR = const RangeValues(0.05, 0.95);
  double zoneSplit = 0.5;
  int script = 0;
  bool autoPos = false;
  bool strictLatin = true;
  bool light = true;
  double bright = 210;
  double interval = 0.33;
  bool adaptive = true;
  bool testMode = true;

  bool running = false;
  bool cancel = false;
  double progress = 0;
  String status = 'Belum mulai.';
  String testResult = '';
  List<Sample> samples = [];

  List<Sub> subs = [];
  bool onlyWarn = false;
  String filesDir = '';

  RangeValues get _effX => autoPos ? const RangeValues(0.02, 0.98) : xR;
  RangeValues get _effY => autoPos ? const RangeValues(0.02, 0.98) : yR;

  @override
  void initState() {
    super.initState();
    loadKamus();
    _init();
  }

  Future<void> _init() async {
    try {
      filesDir = await _ch.invokeMethod<String>('dirs') ?? '';
      await _loadSettings();
      final f = File('$filesDir/subs.json');
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        subs = (j['subs'] as List).map((e) => Sub.fromJson(e as Map<String, dynamic>)).toList();
        name = (j['name'] as String?) ?? name;
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _rec.close();
    _recJp?.close();
    _timeCtl.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  double _d(dynamic v, double def) => v is num ? v.toDouble() : def;

  Future<void> _loadSettings() async {
    final f = File('$filesDir/settings.json');
    if (!await f.exists()) return;
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    yR = RangeValues(_d(j['y0'], yR.start), _d(j['y1'], yR.end));
    xR = RangeValues(_d(j['x0'], xR.start), _d(j['x1'], xR.end));
    zoneSplit = _d(j['zoneSplit'], zoneSplit).clamp(0.05, 0.95).toDouble();
    script = (j['script'] is int) ? (j['script'] as int).clamp(0, 2).toInt() : script;
    autoPos = j['autoPos'] is bool ? j['autoPos'] as bool : autoPos;
    strictLatin = j['strictLatin'] is bool ? j['strictLatin'] as bool : strictLatin;
    light = j['light'] is bool ? j['light'] as bool : light;
    adaptive = j['adaptive'] is bool ? j['adaptive'] as bool : adaptive;
    testMode = j['testMode'] is bool ? j['testMode'] as bool : testMode;
    bright = _d(j['bright'], bright).clamp(120.0, 245.0).toDouble();
    final iv = _d(j['interval'], interval);
    interval = (iv == 0.33 || iv == 0.5 || iv == 1.0) ? iv : 0.33;
    lastUri = j['lastUri'] as String?;
    lastName = (j['lastName'] as String?) ?? '';
  }

  Future<void> _persist() async {
    if (filesDir.isEmpty) return;
    try {
      await File('$filesDir/settings.json').writeAsString(jsonEncode({
        'y0': yR.start,
        'y1': yR.end,
        'x0': xR.start,
        'x1': xR.end,
        'zoneSplit': zoneSplit,
        'script': script,
        'autoPos': autoPos,
        'strictLatin': strictLatin,
        'light': light,
        'bright': bright,
        'interval': interval,
        'adaptive': adaptive,
        'testMode': testMode,
        'lastUri': lastUri,
        'lastName': lastName,
      }));
    } catch (_) {}
  }

  void _set(VoidCallback f) {
    setState(f);
    _persist();
  }

  Future<void> pickVideo() async {
    try {
      final u = await _ch.invokeMethod<String>('pick');
      if (u == null) return;
      await _openUri(u);
    } catch (e) {
      _snack('Gagal: $e');
    }
  }

  Future<void> _openUri(String u) async {
    try {
      setState(() => status = 'Membuka video...');
      final info = await _ch.invokeMapMethod<String, dynamic>('open', {'uri': u});
      if (info == null) throw Exception('Gagal membuka video');
      setState(() {
        uri = u;
        name = info['name'] as String;
        durMs = (info['durationMs'] as num).toInt();
        vw = (info['width'] as num).toInt();
        vh = (info['height'] as num).toInt();
        previewT = math.min(30.0, durMs / 2000.0);
        _timeCtl.text = fmtClock(previewT);
        samples = [];
        lastUri = u;
        lastName = name;
        status = 'Video siap.';
      });
      _persist();
      await loadPreview();
    } catch (e) {
      setState(() => status = 'Belum mulai.');
      _snack('Tidak bisa membuka video: $e');
    }
  }

  Future<void> loadPreview() async {
    if (uri == null) return;
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('frame', {'timeMs': (previewT * 1000).round(), 'maxW': 900});
      if (r == null) return;
      setState(() {
        previewBytes = r['bytes'] as Uint8List;
        previewAspect = (r['w'] as num) / (r['h'] as num);
      });
    } catch (e) {
      _snack('Frame gagal dibaca: $e');
    }
  }

  Future<void> applyTime() async {
    final t = parseClock(_timeCtl.text);
    if (t == null) {
      _snack('Format waktu salah. Contoh: 08:00 (menit:detik)');
      return;
    }
    final maxT = math.max(0.0, durMs / 1000.0 - 1);
    setState(() => previewT = t.clamp(0.0, maxT).toDouble());
    _timeCtl.text = fmtClock(previewT);
    await loadPreview();
  }

  Future<void> nudge(double delta) async {
    final maxT = math.max(0.0, durMs / 1000.0 - 1);
    setState(() => previewT = (previewT + delta).clamp(0.0, maxT).toDouble());
    _timeCtl.text = fmtClock(previewT);
    await loadPreview();
  }

  double _overlap(Rect a, Rect b) {
    if (!a.overlaps(b)) return 0;
    final i = a.intersect(b);
    final area = a.width * a.height;
    return area <= 0 ? 0 : (i.width * i.height) / area;
  }

  Future<String> _ocrFile(String path, double imgH, int zone) async {
    final input = InputImage.fromFilePath(path);
    final lines = <_Ln>[];
    if (script == 0) {
      final r = await _rec.processImage(input);
      for (final b in r.blocks) {
        for (final l in b.lines) {
          lines.add(_Ln(l.text, l.boundingBox));
        }
      }
      if (strictLatin && lines.isNotEmpty) {
        final rj = await _jp.processImage(input);
        final jpBoxes = <Rect>[];
        for (final b in rj.blocks) {
          for (final l in b.lines) {
            if (hasCjk(l.text)) jpBoxes.add(l.boundingBox);
          }
        }
        if (jpBoxes.isNotEmpty) {
          lines.removeWhere((ln) => jpBoxes.any((jb) => _overlap(ln.box, jb) > 0.3));
        }
      }
    } else {
      final r = await _jp.processImage(input);
      for (final b in r.blocks) {
        for (final l in b.lines) {
          lines.add(_Ln(l.text, l.boundingBox));
        }
      }
    }

    final kept = <_Ln>[];
    for (final ln in lines) {
      final cy = ln.box.center.dy / imgH;
      final inZone = zone == 0 ? (cy < zoneSplit) : (cy >= zoneSplit);
      if (!inZone) continue;
      if (autoPos) {
        final ratio = ln.box.height / imgH;
        if (ratio < 0.025 || ratio > 0.12) continue;
        if (letterCount(ln.text) < 3) continue;
      }
      kept.add(ln);
    }
    kept.sort((a, b) => a.box.top.compareTo(b.box.top));
    final raw = cleanText(kept.map((l) => l.text).join('\n'), script);
    return raw
        .split('\n')
        .map((l) => stripWatermark(l))
        .where((l) => l.trim().isNotEmpty && !looksLikeWatermark(l))
        .join('\n');
  }

  Future<String> _ocrBest(String rawPath, int cw, int ch, int zone) async {
    var best = await _ocrFile(rawPath, ch.toDouble(), zone);
    final lt = letterCount(best);
    if (lt >= 6) return best;
    final binPath = await _ch.invokeMethod<String>('binarize');
    if (binPath != null) {
      final binH = ch * (cw > 900 ? 1 : 2) + 20;
      final alt = await _ocrFile(binPath, binH.toDouble(), zone);
      if (letterCount(alt) > lt) best = alt;
    }
    return best;
  }

  Map<String, dynamic> _grabArgs(int tMs, {bool force = false}) => {
        'timeMs': tMs,
        'x0': _effX.start,
        'x1': _effX.end,
        'y0': _effY.start,
        'y1': _effY.end,
        'light': light,
        'bright': bright.round(),
        'minFrac': autoPos ? kMinTextFrac * 0.3 : kMinTextFrac,
        'changeFrac': kChangeFrac,
        'force': force,
      };

  Future<void> testOcr() async {
    if (uri == null) return;
    setState(() => testResult = 'Membaca...');
    try {
      final g = await _ch.invokeMapMethod<String, dynamic>('grab', _grabArgs((previewT * 1000).round(), force: true));
      if (g == null || g['ok'] != true) throw Exception('frame tidak terbaca');
      final path = g['path'] as String?;
      final frac = (g['frac'] as num).toDouble();
      final cw = (g['cw'] as num).toInt();
      final ch = (g['ch'] as num).toInt();
      final warn = frac < (autoPos ? kMinTextFrac * 0.3 : kMinTextFrac)
          ? '(Teks terang tidak terdeteksi. Cek waktu, area, atau turunkan ambang kecerahan.)\n'
          : '';
      if (path == null) {
        setState(() => testResult = '${warn}(kosong)');
        return;
      }
      final top = await _ocrBest(path, cw, ch, 0);
      final bot = await _ocrBest(path, cw, ch, 1);
      final joined = [
        '[zona 0]\n${top.isEmpty ? "(kosong)" : top}',
        '[zona 1]\n${bot.isEmpty ? "(kosong)" : bot}',
      ].join('\n---\n');
      setState(() => testResult = warn + joined);
    } catch (e) {
      setState(() => testResult = 'Error: $e');
    }
  }

  String _sig(int s, int e, int step) =>
      '$uri|$s|$e|$step|${_effX.start.toStringAsFixed(2)},${_effX.end.toStringAsFixed(2)},'
      '${_effY.start.toStringAsFixed(2)},${_effY.end.toStringAsFixed(2)}|$zoneSplit|'
      '$light|${bright.round()}|$adaptive|$script|$autoPos|$strictLatin';

  Future<void> clearTemp() async {
    try {
      final f = File('$filesDir/ocr_raw.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    setState(() {
      samples = [];
      progress = 0;
      status = 'Hasil sementara dihapus.';
    });
  }

  Future<void> runOcr() async {
    if (uri == null || running) return;
    final startMs = testMode ? (previewT * 1000).round() : 0;
    final endMs = testMode ? math.min(durMs, startMs + 60000) : durMs;
    final step = (interval * 1000).round();
    final total = ((endMs - startMs) / step).floor();
    if (total <= 0) {
      _snack('Rentang waktu terlalu pendek.');
      return;
    }
    final sig = _sig(startMs, endMs, step);
    final rawFile = File('$filesDir/ocr_raw.json');
    var list = <Sample>[];
    try {
      if (await rawFile.exists()) {
        final j = jsonDecode(await rawFile.readAsString()) as Map<String, dynamic>;
        if (j['sig'] == sig) {
          list = (j['samples'] as List).map((e) => Sample.fromJson(e as Map<String, dynamic>)).toList();
        }
      }
    } catch (_) {
      list = [];
    }

    Future<void> checkpoint() async {
      try {
        await rawFile.writeAsString(jsonEncode({'sig': sig, 'samples': list.map((s) => s.toJson()).toList()}));
      } catch (_) {}
    }

    int resumedFrames = 0;
    if (list.isNotEmpty) {
      var maxT = 0.0;
      for (final s in list) {
        if (s.t > maxT) maxT = s.t;
      }
      resumedFrames = (((maxT * 1000 - startMs) / step).round() + 1).clamp(0, total);
    }

    setState(() {
      running = true;
      cancel = false;
      samples = list;
      progress = resumedFrames / total;
      status = resumedFrames == 0 ? 'Memulai...' : 'Melanjutkan dari $resumedFrames/$total';
    });
    _persist();
    try {
      await _ch.invokeMethod('serviceStart', {'text': 'OCR dimulai...'});
    } catch (_) {}
    await _ch.invokeMethod('resetPrev');
    final t0 = DateTime.now();
    var lastGrabTexts = <String>['', ''];
    if (resumedFrames > 0) {
      final lastT = (startMs + (resumedFrames - 1) * step) / 1000.0;
      for (final s in list) {
        if ((s.t - lastT).abs() < 1e-6 && s.zone < lastGrabTexts.length) {
          lastGrabTexts[s.zone] = s.text;
        }
      }
    }
    var failStreak = 0;
    var frameFails = 0;

    Future<List<String>> sampleAt(int n) async {
      final tMs = startMs + n * step;
      var texts = <String>['', ''];
      try {
        final g = await _ch.invokeMapMethod<String, dynamic>('grab', _grabArgs(tMs));
        if (g == null || g['ok'] != true) {
          frameFails++;
        } else {
          final frac = (g['frac'] as num).toDouble();
          final changed = (g['changed'] as num).toDouble();
          final path = g['path'] as String?;
          if (frac < (autoPos ? kMinTextFrac * 0.3 : kMinTextFrac)) {
            texts = ['', ''];
          } else if (changed >= 0 && changed < kChangeFrac) {
            texts = lastGrabTexts;
          } else if (path != null) {
            final cw = (g['cw'] as num).toInt();
            final ch = (g['ch'] as num).toInt();
            texts = [
              await _ocrBest(path, cw, ch, 0),
              await _ocrBest(path, cw, ch, 1),
            ];
          }
        }
        failStreak = 0;
      } catch (e) {
        failStreak++;
        if (failStreak >= 20) throw Exception('Terlalu banyak kegagalan beruntun: $e');
      }
      return texts;
    }

    bool sameTexts(List<String> a, List<String> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        final x = a[i];
        final y = b[i];
        if (x.isEmpty || y.isEmpty) {
          if (!(x.isEmpty && y.isEmpty)) return false;
          continue;
        }
        final nx = norm(x);
        final ny = norm(y);
        if (nx != ny && !similar(nx, ny)) return false;
      }
      return true;
    }

    void push(int n, List<String> texts) {
      final t = (startMs + n * step) / 1000.0;
      for (var z = 0; z < texts.length; z++) {
        list.add(Sample(t, texts[z], z));
      }
    }

    try {
      var n = resumedFrames;
      var sinceSave = 0;
      var iter = 0;
      while (n < total) {
        if (cancel) break;
        if (adaptive && n >= 1 && n + 1 < total) {
          final a = lastGrabTexts;
          final c = await sampleAt(n + 1);
          final b = sameTexts(a, c) ? a : await sampleAt(n);
          push(n, b);
          push(n + 1, c);
          lastGrabTexts = c;
          n += 2;
          sinceSave += 2;
        } else {
          final t = await sampleAt(n);
          push(n, t);
          lastGrabTexts = t;
          n += 1;
          sinceSave += 1;
        }
        if (sinceSave >= kSaveEvery) {
          await checkpoint();
          sinceSave = 0;
        }
        if (iter++ % 3 == 0) {
          final el = DateTime.now().difference(t0).inSeconds;
          final doneNow = n - resumedFrames;
          final eta = (doneNow > 10 && el > 0) ? fmtDur(((total - n) * el / doneNow).round()) : 'menghitung...';
          setState(() {
            progress = n / total;
            status = 'OCR $n/$total  •  berjalan ${fmtDur(el)}  •  sisa ±$eta';
          });
          try {
            await _ch.invokeMethod('serviceUpdate', {'text': 'OCR $n/$total  •  sisa ±$eta', 'cur': n, 'max': total});
          } catch (_) {}
        }
      }
      await checkpoint();
      final nonEmpty = list.where((s) => s.text.isNotEmpty).length;
      var merged = mergeSamples(list, interval);
      final videoDur = (endMs - startMs) / 1000.0;
      merged = dropWatermarks(merged, videoDur);
      setState(() {
        samples = list;
        subs = merged;
        progress = n / total;
        final zoneCount = merged.map((s) => s.zone).toSet().length;
        status = cancel
            ? 'Dihentikan di $n/$total. Tekan Mulai untuk melanjutkan.'
            : 'Selesai: $n frame, $nonEmpty berisi teks, ${merged.length} subtitle ($zoneCount zona).' +
                (frameFails > 0 ? ' ($frameFails frame gagal dibaca)' : '') +
                (nonEmpty == 0 ? ' PERINGATAN: tidak ada teks terbaca.' : '');
      });
      await saveSubs();
      if (!cancel) {
        try {
          await _ch.invokeMethod('notifyDone', {'text': 'Selesai: ${merged.length} subtitle.'});
        } catch (_) {}
        if (merged.isNotEmpty) _tabs.animateTo(2);
      }
    } catch (e) {
      await checkpoint();
      setState(() => status = 'Berhenti karena error: $e');
    } finally {
      try {
        await _ch.invokeMethod('serviceStop');
      } catch (_) {}
      if (mounted) setState(() => running = false);
    }
  }

  Future<void> saveSubs() async {
    try {
      await File('$filesDir/subs.json').writeAsString(jsonEncode({'name': name, 'subs': subs.map((s) => s.toJson()).toList()}));
    } catch (_) {}
  }

  String _baseName() {
    var base = name.isEmpty ? 'subtitle' : name;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    return '$base${testMode ? '.TEST' : ''}${script == 1 ? '.ja' : ''}';
  }

  Future<void> _export(String ext) async {
    if (subs.isEmpty) {
      _snack('Belum ada subtitle.');
      return;
    }
    final fileName = '${_baseName()}.$ext';
    try {
      final isAss = ext == 'ass';
      final content = isAss
          ? buildAss(subs, vw > 0 ? vw : 1920, vh > 0 ? vh : 1080)
          : buildSrt(subs);
      final where = await _ch.invokeMethod<String>('save', {
        'name': fileName,
        'text': content,
        'mime': isAss ? 'text/x-ssa' : 'application/x-subrip',
      });
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('${ext.toUpperCase()} tersimpan'),
          content: Text(
            '$where\n\n'
            '${isAss ? "Format ASS: zona atas di atas, zona bawah di bawah." : "Format SRT: teks polos."}',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      _snack('Gagal menyimpan: $e');
    }
  }

  Future<void> exportSrt() => _export('srt');
  Future<void> exportAss() => _export('ass');

  // ---- perbaikan otomatis (frekuensi) ----
  Future<void> autoFix() async {
    final fixes = buildFixes(subs);
    if (fixes.isEmpty) {
      _snack('Tidak ada koreksi yang cukup yakin.');
      return;
    }
    final list = fixes.entries.map((e) => '${e.key} → ${e.value}').join('\n');
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${fixes.length} koreksi ditemukan'),
        content: SingleChildScrollView(child: Text(list)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Terapkan')),
        ],
      ),
    );
    if (yes != true) return;
    for (final s in subs) {
      s.text = s.text.replaceAllMapped(_wordRe, (m) {
        final w = m.group(0)!;
        final f = fixes[w.toLowerCase()];
        return f == null ? w : _matchCase(w, f);
      });
    }
    setState(() {});
    await saveSubs();
    _snack('Koreksi diterapkan.');
  }

  // ---- analisis kamus ----
  Future<void> analyzeKamus() async {
    if (!kKamusReady) await loadKamus();
    if (kKamus.isEmpty) {
      _snack('Kamus tidak tersedia. Pastikan assets/kamus_id.txt ada.');
      return;
    }
    if (subs.isEmpty) return;

    setState(() => status = 'Menganalisis kamus...');

    final usulan = analyzeText(subs);
    if (usulan.isEmpty) {
      _snack('Tidak ada kata yang perlu dikoreksi.');
      return;
    }

    // dialog
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) {
          return AlertDialog(
            title: Text('${usulan.length} usulan koreksi'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: usulan.length,
                itemBuilder: (c, i) {
                  final u = usulan[i];
                  return CheckboxListTile(
                    dense: true,
                    value: u.dicentang,
                    title: Text('${u.asli}  →  ${u.usul}'),
                    subtitle: Text(u.alasan),
                    onChanged: (v) => setD(() => u.dicentang = v ?? false),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () {
                  // terapkan
                  var n = 0;
                  for (final s in subs) {
                    s.text = s.text.replaceAllMapped(_wordRe, (m) {
                      final w = m.group(0)!;
                      for (final u in usulan) {
                        if (u.dicentang && u.asli == w) {
                          n++;
                          return u.usul;
                        }
                      }
                      return w;
                    });
                  }
                  Navigator.pop(c);
                  setState(() {});
                  saveSubs();
                  _snack('$n kata dikoreksi.');
                },
                child: const Text('Terapkan yg dicentang'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> findReplace() async {
    final cari = TextEditingController();
    final ganti = TextEditingController();
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cari & ganti'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: cari, decoration: const InputDecoration(labelText: 'Cari')),
          TextField(controller: ganti, decoration: const InputDecoration(labelText: 'Ganti dengan')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ganti semua')),
        ],
      ),
    );
    if (yes != true || cari.text.isEmpty) return;
    var n = 0;
    for (final s in subs) {
      if (s.text.contains(cari.text)) {
        s.text = s.text.replaceAll(cari.text, ganti.text);
        n++;
      }
    }
    setState(() {});
    await saveSubs();
    _snack('$n subtitle diubah.');
  }

  Future<void> editSub(Sub s) async {
    final cs = TextEditingController(text: fmtSrt(s.start));
    final ce = TextEditingController(text: fmtSrt(s.end));
    final ct = TextEditingController(text: s.text);
    Uint8List? frame;
    String? err;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('Edit subtitle'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (s.warn.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('⚠ ${s.warn.join(', ')}', style: const TextStyle(color: Colors.orange)),
                ),
              if (frame != null) Image.memory(frame!),
              TextField(controller: cs, decoration: const InputDecoration(labelText: 'Mulai (00:00:00,000)')),
              TextField(controller: ce, decoration: const InputDecoration(labelText: 'Selesai')),
              TextField(controller: ct, maxLines: 4, decoration: const InputDecoration(labelText: 'Teks')),
              if (err != null) Text(err!, style: const TextStyle(color: Colors.red)),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (uri == null) {
                  setD(() => err = 'Buka video dulu di tab Siapkan untuk melihat frame.');
                  return;
                }
                try {
                  final t = (s.start + s.end) / 2;
                  final r = await _ch.invokeMapMethod<String, dynamic>('frame', {'timeMs': (t * 1000).round(), 'maxW': 700});
                  setD(() => frame = r?['bytes'] as Uint8List?);
                } catch (e) {
                  setD(() => err = 'Frame gagal: $e');
                }
              },
              child: const Text('Lihat frame'),
            ),
            TextButton(
              onPressed: () {
                final i = subs.indexOf(s);
                if (i >= 0 && i + 1 < subs.length && subs[i + 1].zone == s.zone) {
                  final n = subs.removeAt(i + 1);
                  s.text = '${s.text}\n${n.text}';
                  s.end = n.end;
                  s.warn = [];
                  setState(() {});
                  saveSubs();
                }
                Navigator.pop(c);
              },
              child: const Text('Gabung ke berikutnya'),
            ),
            TextButton(
              onPressed: () {
                final ns = Sub(s.end + 0.05, s.end + 2.05, '(ketik teks)', [], zone: s.zone);
                subs.insert(subs.indexOf(s) + 1, ns);
                setState(() {});
                saveSubs();
                Navigator.pop(c);
              },
              child: const Text('Tambah setelah ini'),
            ),
            TextButton(
              onPressed: () {
                subs.remove(s);
                setState(() {});
                saveSubs();
                Navigator.pop(c);
              },
              child: const Text('Hapus', style: TextStyle(color: Colors.red)),
            ),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Batal')),
            FilledButton(
              onPressed: () {
                try {
                  final st = parseSrt(cs.text);
                  final en = parseSrt(ce.text);
                  if (en <= st) {
                    setD(() => err = 'Waktu selesai harus setelah mulai.');
                    return;
                  }
                  s.start = st;
                  s.end = en;
                  s.text = ct.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
                  s.warn = [];
                  subs.sort((a, b) {
                    final c = a.start.compareTo(b.start);
                    return c != 0 ? c : a.zone.compareTo(b.zone);
                  });
                  setState(() {});
                  saveSubs();
                  Navigator.pop(c);
                } on FormatException catch (e) {
                  setD(() => err = e.message);
                }
              },
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hardsub OCR'),
        bottom: TabBar(controller: _tabs, tabs: const [
          Tab(icon: Icon(Icons.tune), text: 'Siapkan'),
          Tab(icon: Icon(Icons.play_circle_outline), text: 'Proses'),
          Tab(icon: Icon(Icons.subtitles_outlined), text: 'Hasil'),
        ]),
      ),
      body: TabBarView(
        controller: _tabs,
        physics: const NeverScrollableScrollPhysics(),
        children: [_tabSiapkan(), _tabProses(), _tabHasil()],
      ),
    );
  }

  Widget _card(String title, List<Widget> children, {String? hint}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (hint != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(hint, style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    );
  }

  String _pct(double v) => '${(v * 100).round()}%';

  Widget _tabSiapkan() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      _card('1. Video', [
        FilledButton.icon(onPressed: running ? null : pickVideo, icon: const Icon(Icons.video_file), label: const Text('Pilih video (MP4 / MKV)')),
        if (uri == null && lastUri != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: running ? null : () => _openUri(lastUri!),
              icon: const Icon(Icons.history),
              label: Text('Buka lagi: ${lastName.isEmpty ? 'video terakhir' : lastName}', overflow: TextOverflow.ellipsis),
            ),
          ),
        if (uri != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('$name\n${vw}x$vh  •  ${durMs ~/ 60000} menit ${(durMs ~/ 1000) % 60} dtk'),
          ),
      ]),
      if (uri != null) ...[
        _card('2. Pratinjau & waktu', [
          if (previewBytes != null)
            AspectRatio(
              aspectRatio: previewAspect,
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(previewBytes!, fit: BoxFit.fill, gaplessPlayback: true),
                CustomPaint(painter: _CropPainter(_effX, _effY, zoneSplit)),
              ]),
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _timeCtl,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(labelText: 'Waktu (menit:detik)', hintText: '08:00', border: OutlineInputBorder(), isDense: true),
                onSubmitted: (_) => applyTime(),
              ),
            ),
            IconButton(onPressed: () => nudge(-5), icon: const Icon(Icons.replay_5)),
            IconButton(onPressed: () => nudge(5), icon: const Icon(Icons.forward_5)),
            FilledButton(onPressed: applyTime, child: const Text('Tampilkan')),
          ]),
        ], hint: 'Ketik waktu yang ADA subtitle-nya, mis. 08:00 atau 1:08:00.'),
        _card('3. Area subtitle', [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Posisi subtitle berpindah-pindah'),
            subtitle: const Text('Baca seluruh layar (atas / tengah / bawah).'),
            value: autoPos,
            onChanged: (v) => _set(() => autoPos = v),
          ),
          if (!autoPos) ...[
            Text('Atas – Bawah: ${_pct(yR.start)} – ${_pct(yR.end)}'),
            RangeSlider(values: yR, min: 0, max: 1, onChanged: (v) => setState(() => yR = v), onChangeEnd: (_) => _persist()),
            Text('Kiri – Kanan: ${_pct(xR.start)} – ${_pct(xR.end)}'),
            RangeSlider(values: xR, min: 0, max: 1, onChanged: (v) => setState(() => xR = v), onChangeEnd: (_) => _persist()),
            const Text('Kotak merah harus menutupi subtitle saja.', style: TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 8),
          Text('Garis pemisah zona atas/bawah: ${_pct(zoneSplit)}'),
          Slider(
            value: zoneSplit,
            min: 0.05,
            max: 0.95,
            divisions: 18,
            label: _pct(zoneSplit),
            onChanged: (v) => setState(() => zoneSplit = v),
            onChangeEnd: (_) => _persist(),
          ),
        ]),
        _card('4. Jenis tulisan subtitle', [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Latin')),
              ButtonSegment(value: 1, label: Text('Jepang')),
              ButtonSegment(value: 2, label: Text('Keduanya')),
            ],
            selected: {script},
            onSelectionChanged: (s) => _set(() => script = s.first),
          ),
          if (script == 0)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Buang area tulisan Jepang'),
              value: strictLatin,
              onChanged: (v) => _set(() => strictLatin = v),
            ),
        ]),
        _card('5. Tes', [
          OutlinedButton.icon(onPressed: running ? null : testOcr, icon: const Icon(Icons.science), label: const Text('Tes OCR pada waktu ini')),
          if (testResult.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(testResult, style: const TextStyle(fontSize: 16))),
        ]),
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ExpansionTile(
            title: const Text('Pengaturan lanjutan'),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Teks subtitle terang'),
                value: light,
                onChanged: (v) => _set(() => light = v),
              ),
              Text('Ambang kecerahan: ${bright.round()}'),
              Slider(value: bright, min: 120, max: 245, onChanged: (v) => setState(() => bright = v), onChangeEnd: (_) => _persist()),
              Row(children: [
                const Text('Interval: '),
                DropdownButton<double>(
                  value: interval,
                  items: const [
                    DropdownMenuItem(value: 0.33, child: Text('0,33 dtk')),
                    DropdownMenuItem(value: 0.5, child: Text('0,5 dtk')),
                    DropdownMenuItem(value: 1.0, child: Text('1 dtk')),
                  ],
                  onChanged: (v) => _set(() => interval = v ?? 0.33),
                ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mode cepat adaptif'),
                value: adaptive,
                onChanged: (v) => _set(() => adaptive = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mode uji (60 detik)'),
                value: testMode,
                onChanged: (v) => _set(() => testMode = v),
              ),
            ],
          ),
        ),
        FilledButton.icon(onPressed: () => _tabs.animateTo(1), icon: const Icon(Icons.arrow_forward), label: const Text('Lanjut ke Proses')),
        const SizedBox(height: 24),
      ],
    ]);
  }

  Widget _tabProses() {
    final scriptName = ['Latin', 'Jepang', 'Latin + Jepang'][script];
    final area = autoPos ? 'seluruh layar' : 'kotak ${_pct(yR.start)}–${_pct(yR.end)}';
    return ListView(padding: const EdgeInsets.all(12), children: [
      _card('Ringkasan', [
        Text(uri == null
            ? 'Pilih video dulu di tab Siapkan.'
            : '$name\n'
                'Mode: ${testMode ? 'UJI 60 detik' : 'PENUH'}\n'
                'Tulisan: $scriptName\n'
                'Area: $area\n'
                'Interval: $interval dtk${adaptive ? ' (adaptif)' : ''}'),
      ]),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: (uri == null || running) ? null : runOcr,
            icon: const Icon(Icons.play_arrow),
            label: Text(samples.isNotEmpty && !running ? 'Mulai / Lanjutkan' : 'Mulai'),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: running ? () => setState(() => cancel = true) : null, child: const Text('Stop')),
      ]),
      const SizedBox(height: 12),
      LinearProgressIndicator(value: (running || progress > 0) ? progress : 0.0),
      const SizedBox(height: 8),
      Text(status),
      const SizedBox(height: 12),
      if (!running && samples.isNotEmpty)
        Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: clearTemp, child: const Text('Hapus hasil sementara'))),
    ]);
  }

  Widget _tabHasil() {
    final shown = <int>[];
    for (var i = 0; i < subs.length; i++) {
      if (!onlyWarn || subs[i].warn.isNotEmpty) shown.add(i);
    }
    final nw = subs.where((s) => s.warn.isNotEmpty).length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${subs.length} subtitle • $nw ⚠'),
          FilterChip(label: const Text('Hanya ⚠'), selected: onlyWarn, onSelected: (v) => setState(() => onlyWarn = v)),
          ActionChip(label: const Text('Perbaiki otomatis'), onPressed: subs.isEmpty ? null : autoFix),
          ActionChip(label: const Text('Analisis kamus'), onPressed: subs.isEmpty ? null : analyzeKamus),
          ActionChip(label: const Text('Cari & ganti'), onPressed: subs.isEmpty ? null : findReplace),
        ]),
      ),
      Expanded(
        child: subs.isEmpty
            ? const Center(child: Text('Belum ada hasil.'))
            : ListView.builder(
                itemCount: shown.length,
                itemBuilder: (c, k) {
                  final i = shown[k];
                  final s = subs[i];
                  return ListTile(
                    dense: true,
                    title: Text(s.text.replaceAll('\n', ' / ')),
                    subtitle: Text('${i + 1}.  [zona ${s.zone}]  ${fmtSrt(s.start)} → ${fmtSrt(s.end)}${s.warn.isEmpty ? '' : '\n⚠ ${s.warn.join(', ')}'}',
                        style: TextStyle(color: s.warn.isEmpty ? null : Colors.orange)),
                    onTap: () => editSub(s),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: exportSrt,
              icon: const Icon(Icons.description_outlined),
              label: const Text('Ekspor SRT'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: exportAss,
              icon: const Icon(Icons.download),
              label: const Text('Ekspor ASS'),
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _CropPainter extends CustomPainter {
  final RangeValues x;
  final RangeValues y;
  final double split;
  _CropPainter(this.x, this.y, this.split);
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(x.start * size.width, y.start * size.height, x.end * size.width, y.end * size.height);
    canvas.drawRect(
        r,
        Paint()
          ..color = Colors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    final yLine = split * size.height;
    canvas.drawLine(
      Offset(0, yLine),
      Offset(size.width, yLine),
      Paint()
        ..color = Colors.amber
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.x != x || old.y != y || old.split != split;
}
