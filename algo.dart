// =====================================================================
//  ALGORITMA MURNI (tanpa Flutter) — bisa dites dengan `flutter test`.
//  Isi: util teks/waktu, kandidat OCR, blok baris, pelacakan antar-frame,
//  skor "subtitle atau bukan", pencocokan dengan SRT referensi,
//  pemulihan teks terpotong, ekspor SRT/ASS.
// =====================================================================
import 'dart:math' as math;

// ----------------------- konstanta -----------------------
const double kSim = 0.85; // kemiripan teks agar dianggap sama
const double kMaxDropoutSec = 0.7; // OCR gagal sesaat di tengah subtitle masih dianggap sama
const double kMinDuration = 0.7;
const double kLikely = 0.60; // skor >= ini: kemungkinan subtitle
const double kDoubt = 0.40; // skor >= ini: meragukan; di bawahnya: kemungkinan bukan subtitle

// kelas hasil
const int clsLikely = 0;
const int clsDoubt = 1;
const int clsNon = 2;
const int clsMissing = 3; // ada di subtitle referensi, tidak terbaca OCR

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

/// 125 detik -> "02:05" ; 3725 detik -> "1:02:05"
String fmtClock(double t) {
  final s = t.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String p(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${p(m)}:${p(sec)}' : '${p(m)}:${p(sec)}';
}

/// "08:00" (menit:detik) atau "1:08:00" (jam:menit:detik) -> detik. null jika salah format.
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

/// Bersihkan hasil OCR. mode: 0 = Latin saja, 1 = Jepang saja, 2 = keduanya.
String cleanText(String t, int mode) {
  final out = <String>[];
  for (var line in t.split('\n')) {
    final nCjk = _cjk.allMatches(line).length;
    if (mode == 0) {
      if (nCjk > 0) {
        final latin = RegExp(r'[A-Za-z]').allMatches(line).length;
        if (latin >= 3 * nCjk && latin >= 3) {
          line = line.replaceAll(_cjk, ' '); // dominan Latin: buang huruf asingnya saja
        } else {
          continue; // dominan Jepang: buang seluruh baris
        }
      }
    } else if (mode == 1) {
      if (nCjk == 0) continue; // Jepang saja: buang baris tanpa huruf Jepang
    }
    line = line.replaceAll(RegExp(r'\s+'), ' ').trim();
    final compact = line.replaceAll(' ', '');
    if (compact.isEmpty) continue;
    final alnum = _reAlnum.allMatches(compact).length;
    if (alnum >= 1 && alnum / compact.length >= 0.6) out.add(line);
  }
  return out.join('\n');
}

int lev(String a, String b) {
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
  return 1.0 - lev(a, b) / m;
}

bool similar(String a, String b) {
  if (a == b) return true;
  final minLen = (hasCjk(a) || hasCjk(b)) ? 3 : 6;
  if (math.min(a.length, b.length) < minLen) return false; // teks pendek harus identik
  return simRatio(a, b) >= kSim;
}

// ----------------------- model OCR -----------------------
double _r4(double v) => (v * 10000).roundToDouble() / 10000;

/// Satu baris teks hasil OCR beserta kotaknya (koordinat 0..1 terhadap seluruh frame video).
class Cand {
  String text;
  double l, t, r, b;
  double outline; // porsi piksel teks yang punya tepi gelap di dekatnya (-1 = tidak diketahui)
  double fill; // porsi piksel teks terang di dalam kotak (-1 = tidak diketahui)
  Cand(this.text, this.l, this.t, this.r, this.b, {this.outline = -1.0, this.fill = -1.0});
  double get h => b - t;
  double get w => r - l;
  Cand copy() => Cand(text, l, t, r, b, outline: outline, fill: fill);
  Map<String, dynamic> toJson() => {'x': text, 'l': _r4(l), 't': _r4(t), 'r': _r4(r), 'b': _r4(b), 'o': _r4(outline), 'f': _r4(fill)};
  factory Cand.fromJson(Map<String, dynamic> j) => Cand(j['x'] as String, (j['l'] as num).toDouble(), (j['t'] as num).toDouble(),
      (j['r'] as num).toDouble(), (j['b'] as num).toDouble(),
      outline: (j['o'] as num?)?.toDouble() ?? -1.0, fill: (j['f'] as num?)?.toDouble() ?? -1.0);
}

/// Hasil OCR satu area pada satu waktu.
class Sample {
  double t;
  List<Cand> cands;
  Sample(this.t, this.cands);
  String get text => cands.map((c) => c.text).join('\n');
  Map<String, dynamic> toJson() => {'t': t, 'c': cands.map((c) => c.toJson()).toList()};
  factory Sample.fromJson(Map<String, dynamic> j) =>
      Sample((j['t'] as num).toDouble(), (j['c'] as List).map((e) => Cand.fromJson(e as Map<String, dynamic>)).toList());
}

/// Satu atau beberapa baris yang berdekatan (satu subtitle) pada satu frame.
class Block {
  String text;
  double l, t, r, b;
  int nlines;
  double lineH;
  double outline;
  double fill;
  Block(this.text, this.l, this.t, this.r, this.b, this.nlines, this.lineH, this.outline, this.fill);
  double get cx => (l + r) / 2;
  double get cy => (t + b) / 2;
}

double meanPos(List<double> vals) {
  var s = 0.0;
  var n = 0;
  for (final v in vals) {
    if (v >= 0) {
      s += v;
      n++;
    }
  }
  return n == 0 ? -1.0 : s / n;
}

/// Gabung potongan satu baris (kiri-kanan) lalu kelompokkan baris berdekatan menjadi blok.
List<Block> buildBlocks(List<Cand> cands) {
  final items = cands.map((c) => c.copy()).toList()
    ..sort((a, b) {
      final c = a.t.compareTo(b.t);
      return c != 0 ? c : a.l.compareTo(b.l);
    });
  final lines = <Cand>[];
  for (final c in items) {
    var merged = false;
    for (final ln in lines) {
      final ov = math.min(ln.b, c.b) - math.max(ln.t, c.t);
      final mh = math.min(ln.h, c.h);
      if (mh <= 0) continue;
      final gap = math.max(c.l - ln.r, ln.l - c.r);
      if (ov >= 0.6 * mh && gap <= 1.5 * math.max(ln.h, c.h)) {
        final left = ln.l <= c.l ? ln : c;
        final right = ln.l <= c.l ? c : ln;
        ln.text = '${left.text} ${right.text}'.trim();
        ln.outline = meanPos([ln.outline, c.outline]);
        ln.fill = meanPos([ln.fill, c.fill]);
        ln.l = math.min(ln.l, c.l);
        ln.r = math.max(ln.r, c.r);
        ln.t = math.min(ln.t, c.t);
        ln.b = math.max(ln.b, c.b);
        merged = true;
        break;
      }
    }
    if (!merged) lines.add(c);
  }
  lines.sort((a, b) {
    final c = a.t.compareTo(b.t);
    return c != 0 ? c : a.l.compareTo(b.l);
  });
  final groups = <List<Cand>>[];
  for (final ln in lines) {
    if (groups.isNotEmpty) {
      final g = groups.last;
      var gl = g.first.l, gr = g.first.r, gb = g.first.b, hsum = 0.0;
      for (final x in g) {
        gl = math.min(gl, x.l);
        gr = math.max(gr, x.r);
        gb = math.max(gb, x.b);
        hsum += x.h;
      }
      final lh = hsum / g.length;
      final gap = ln.t - gb;
      final hov = math.min(gr, ln.r) - math.max(gl, ln.l);
      final narrow = math.min(gr - gl, ln.w);
      final hratio = lh > 0 ? ln.h / lh : 99.0;
      if (gap <= 0.7 * lh && gap >= -0.5 * lh && hov >= 0.25 * narrow && hratio >= 0.6 && hratio <= 1.67) {
        g.add(ln);
        continue;
      }
    }
    groups.add([ln]);
  }
  final out = <Block>[];
  for (final g in groups) {
    var l = g.first.l, t = g.first.t, r = g.first.r, b = g.first.b, hsum = 0.0;
    for (final x in g) {
      l = math.min(l, x.l);
      t = math.min(t, x.t);
      r = math.max(r, x.r);
      b = math.max(b, x.b);
      hsum += x.h;
    }
    out.add(Block(g.map((x) => x.text).join('\n'), l, t, r, b, g.length, hsum / g.length,
        meanPos(g.map((x) => x.outline).toList()), meanPos(g.map((x) => x.fill).toList())));
  }
  return out;
}

// ----------------------- kemiripan sebagian (potongan kalimat) -----------------------
/// Seberapa utuh `a` (pendek) muncul sebagai potongan di dalam `b`. 1.0 = utuh.
double partialRatio(String a, String b) {
  final m = a.length;
  if (m == 0) return 0.0;
  var prev = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= m; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    prev = cur;
  }
  var best = prev[0];
  for (final v in prev) {
    if (v < best) best = v;
  }
  return 1.0 - best / m;
}

bool containedIn(String shortN, String longN) {
  if (shortN.length < 6 || longN.length <= shortN.length) return false;
  return partialRatio(shortN, longN) >= 0.88;
}

// ----------------------- pelacakan antar-frame -----------------------
class Track {
  final List<double> ts = [];
  final List<Block> blocks = [];
  final Map<String, int> counts = {};
  final Map<String, Map<String, int>> rep = {};
  double first;
  double last;
  Track(double t, Block b)
      : first = t,
        last = t {
    add(t, b);
  }
  int get n => ts.length;
  Block get lastBlock => blocks.last;
  void add(double t, Block b) {
    ts.add(t);
    blocks.add(b);
    final nn = norm(b.text);
    counts[nn] = (counts[nn] ?? 0) + 1;
    final m = rep.putIfAbsent(nn, () => <String, int>{});
    m[b.text] = (m[b.text] ?? 0) + 1;
    if (t > last) last = t;
    if (t < first) first = t;
  }

  String get refN {
    String? best;
    for (final e in counts.entries) {
      if (best == null || e.value > counts[best]! || (e.value == counts[best]! && e.key.length > best.length)) best = e.key;
    }
    return best ?? '';
  }

  double med(double Function(Block) f) {
    final v = blocks.map(f).toList()..sort();
    return v[v.length ~/ 2];
  }
}

double _linkScore(Track tr, Block blk, double t, double interval) {
  const eps = 1e-6;
  final gap = t - tr.last;
  final nb = norm(blk.text);
  final longEnough = nb.length >= (hasCjk(nb) ? 3 : 6);
  final allowed = longEnough ? interval + kMaxDropoutSec + eps : interval + eps;
  if (gap > allowed) return 0.0;
  final last = tr.lastBlock;
  final posOk = (blk.cx - last.cx).abs() <= 0.2 &&
      (math.min((blk.t - last.t).abs(), (blk.b - last.b).abs()) <= 0.04 || (blk.cy - last.cy).abs() <= 0.05);
  if (!posOk) return 0.0;
  final rn = tr.refN;
  final lastn = norm(last.text);
  if (similar(nb, lastn) || similar(nb, rn)) {
    return 1.0 + math.max(simRatio(nb, lastn), simRatio(nb, rn)) * 0.5;
  }
  if (containedIn(nb, rn) || containedIn(nb, lastn)) return 0.9; // potongan dari teks yang sudah mapan
  if ((containedIn(rn, nb) || containedIn(lastn, nb)) && tr.n <= 3) return 0.8; // teks lebih lengkap menyusul
  return 0.0;
}

/// Satu area. Setiap sampel boleh berisi beberapa blok (mis. subtitle + tulisan di benda).
List<Track> buildTracks(List<Sample> samples, double interval) {
  const eps = 1e-6;
  final sorted = [...samples]..sort((a, b) => a.t.compareTo(b.t));
  var open = <Track>[];
  final done = <Track>[];
  for (final s in sorted) {
    final blocks = buildBlocks(s.cands).where((b) => letterCount(b.text) >= 2).toList();
    final pairs = <List<num>>[];
    for (var bi = 0; bi < blocks.length; bi++) {
      for (var ti = 0; ti < open.length; ti++) {
        final sc = _linkScore(open[ti], blocks[bi], s.t, interval);
        if (sc > 0) pairs.add(<num>[sc, bi, ti]);
      }
    }
    pairs.sort((a, b) => b[0].compareTo(a[0]));
    final ab = <int, int>{};
    final at = <int>{};
    for (final p in pairs) {
      final bi = p[1].toInt();
      final ti = p[2].toInt();
      if (ab.containsKey(bi) || at.contains(ti)) continue;
      ab[bi] = ti;
      at.add(ti);
    }
    for (final e in ab.entries) {
      open[e.value].add(s.t, blocks[e.key]);
    }
    for (var bi = 0; bi < blocks.length; bi++) {
      if (!ab.containsKey(bi)) open.add(Track(s.t, blocks[bi]));
    }
    final keep = <Track>[];
    for (final tr in open) {
      final nb = norm(tr.lastBlock.text);
      final le = nb.length >= (hasCjk(nb) ? 3 : 6);
      final allowed = interval + (le ? kMaxDropoutSec : 0.0) + eps;
      if (s.t - tr.last > allowed) {
        done.add(tr);
      } else {
        keep.add(tr);
      }
    }
    open = keep;
  }
  done.addAll(open);
  done.sort((a, b) => a.first.compareTo(b.first));

  // Sampel tunggal yang mirip tetangganya = salah baca sesaat -> gabungkan ke tetangga
  final absorbed = <int>{};
  if (interval <= 0.6) {
    for (var i = 0; i < done.length; i++) {
      final tr = done[i];
      if (tr.n != 1 || absorbed.contains(i)) continue;
      final t0 = tr.ts.first;
      final b0 = tr.blocks.first;
      final n0 = norm(b0.text);
      int? best;
      var bestR = 0.55;
      for (var j = 0; j < done.length; j++) {
        final o = done[j];
        if (j == i || absorbed.contains(j) || o.n < 2) continue;
        final gap = o.last <= t0 ? t0 - o.last : o.first - t0;
        if (gap < 0 || gap > interval + eps) continue;
        final lb = o.lastBlock;
        if ((b0.cx - lb.cx).abs() > 0.2 || (b0.cy - lb.cy).abs() > 0.06) continue;
        final r = simRatio(n0, o.refN);
        if (r >= bestR) {
          best = j;
          bestR = r;
        }
      }
      if (best != null) {
        done[best].add(t0, b0);
        absorbed.add(i);
      }
    }
  }
  final out = <Track>[];
  for (var i = 0; i < done.length; i++) {
    if (!absorbed.contains(i)) out.add(done[i]);
  }
  return out;
}

class PickedText {
  final String text;
  final String? alt;
  final String? tag;
  PickedText(this.text, this.alt, this.tag);
}

String _repText(Track tr, String n) {
  final d = tr.rep[n]!;
  String? best;
  for (final e in d.entries) {
    if (best == null || e.value > d[best]! || (e.value == d[best]! && e.key.length > best.length)) best = e.key;
  }
  return best ?? '';
}

/// Pilih versi teks terlengkap yang didukung >= 2 sampel. Tidak mengarang bagian yang hilang.
PickedText pickText(Track tr) {
  final mode = tr.refN;
  final longer = <String>[];
  for (final n in tr.counts.keys) {
    if (n != mode && n.length >= mode.length * 1.25 && containedIn(mode, n)) {
      final txt = _repText(tr, n);
      final lc = letterCount(txt);
      final cc = txt.replaceAll(RegExp(r'\s'), '').length;
      if (cc > 0 && lc / cc >= 0.8) longer.add(n);
    }
  }
  var chosen = mode;
  String? alt;
  String? tag;
  if (longer.isNotEmpty) {
    var best = longer.first;
    for (final n in longer) {
      final cb = tr.counts[best]!;
      final cn = tr.counts[n]!;
      if (cn > cb || (cn == cb && n.length > best.length)) best = n;
    }
    if (tr.counts[best]! >= 2) {
      chosen = best;
    } else {
      alt = _repText(tr, best);
      tag = 'trunc';
    }
  }
  return PickedText(_repText(tr, chosen), alt, tag);
}

// ----------------------- skor: subtitle atau bukan? -----------------------
bool _isAlpha(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 0xC0 && c <= 0x24F);
bool _isUpper(int c) => c >= 65 && c <= 90;
bool _isLower(int c) => c >= 97 && c <= 122;
bool _isDigit(int c) => c >= 48 && c <= 57;
bool _isVowel(int c) => 'aeiouAEIOU'.contains(String.fromCharCode(c));

/// Trapesium: 0 di <=a, naik ke 1 di b, tetap 1 sampai c, turun ke 0 di >=d.
double trap(double x, double a, double b, double c, double d) {
  if (x <= a || x >= d) return 0.0;
  if (x < b) return (x - a) / (b - a);
  if (x <= c) return 1.0;
  return (d - x) / (d - c);
}

bool suspiciousToken(String tok) {
  final core = tok.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (core.isEmpty) return true;
  final units = core.codeUnits;
  final hasD = units.any(_isDigit);
  final hasL = units.any(_isAlpha);
  if (hasD && hasL && core.length <= 8) return true; // mis. "O5Mo"
  if (hasL && core.length >= 3 && !units.any(_isVowel)) return true;
  var inner = 0;
  for (var i = 1; i < units.length; i++) {
    if (_isUpper(units[i]) && _isLower(units[i - 1])) inner++;
  }
  if (inner >= 1 && core.length <= 6) return true;
  return false;
}

/// 0..1: seberapa mirip kalimat/dialog (bukan kode, logo, atau tulisan di benda).
double textScore(String text) {
  final flat = text.replaceAll('\n', ' ');
  final toks = flat.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
  final letters = flat.codeUnits.where(_isAlpha).toList();
  if (letters.length < 2) return 0.0;
  final nw = toks.length;
  final wordScore = nw == 1 ? 0.5 : (nw == 2 ? 0.8 : 1.0);
  final vr = letters.where(_isVowel).length / letters.length;
  final vowel = trap(vr, 0.12, 0.28, 0.55, 0.80);
  final sus = toks.where(suspiciousToken).length / math.max(1, nw);
  final firstAlpha = letters.first;
  var punct = 0.0;
  final trimmed = flat.trimRight();
  if (trimmed.isNotEmpty && '.?!…,"\'”’)-'.contains(trimmed[trimmed.length - 1])) punct += 0.5;
  if (_isUpper(firstAlpha) || !letters.any(_isUpper)) punct += 0.5;
  var s = 0.35 * wordScore + 0.25 * vowel + 0.25 * (1 - sus) + 0.15 * punct;
  if (nw == 1 && letters.length >= 3 && letters.every(_isUpper)) s *= 0.55;
  if (letters.length >= 20) s = math.min(1.0, s + 0.05);
  return math.max(0.0, math.min(1.0, s));
}

class TrackFeat {
  final double cx, cy, lineH, outline, fill, dur;
  final int n;
  TrackFeat(this.cx, this.cy, this.lineH, this.outline, this.fill, this.dur, this.n);
}

TrackFeat trackFeatures(Track tr, double interval) => TrackFeat(
      tr.med((b) => b.cx),
      tr.med((b) => b.cy),
      tr.med((b) => b.lineH),
      meanPos(tr.blocks.map((b) => b.outline).toList()),
      meanPos(tr.blocks.map((b) => b.fill).toList()),
      tr.last - tr.first + interval,
      tr.n,
    );

/// Konteks video: tinggi huruf & posisi lajur subtitle yang "dipelajari" dari kandidat yang sangat meyakinkan.
class Ctx {
  double hMed = -1.0;
  List<int>? laneBins;
  int nAnchor = 0;
}

Ctx buildCtx(List<Track> tracks, double interval) {
  final ctx = Ctx();
  final hs = <double>[];
  final cys = <double>[];
  for (final tr in tracks) {
    final f = trackFeatures(tr, interval);
    final txt = pickText(tr).text;
    if (tr.n >= 2 && textScore(txt) >= 0.75 && trap(f.lineH, 0.015, 0.03, 0.08, 0.13) >= 0.8) {
      hs.add(f.lineH);
      cys.add(f.cy);
    }
  }
  ctx.nAnchor = hs.length;
  if (hs.length >= 5) {
    hs.sort();
    ctx.hMed = hs[hs.length ~/ 2];
    final bins = List<int>.filled(51, 0);
    for (final cy in cys) {
      bins[math.min(50, (cy * 50).floor())]++;
    }
    ctx.laneBins = bins;
  }
  return ctx;
}

double laneScore(Ctx ctx, double cy) {
  final bins = ctx.laneBins;
  if (bins == null) return 0.5;
  final i = math.min(50, math.max(0, (cy * 50).floor()));
  var c = 0;
  for (var k = math.max(0, i - 2); k <= math.min(50, i + 2); k++) {
    c += bins[k];
  }
  final need = math.max(3.0, 0.15 * ctx.nAnchor);
  return math.min(1.0, c / need);
}

double durationScore(double dur, int n) {
  var d = trap(dur, 0.1, 0.6, 9.0, 40.0);
  if (n <= 1) d = math.min(d, 0.45);
  return d;
}

double scoreTrack(Track tr, Ctx ctx, double interval) {
  final f = trackFeatures(tr, interval);
  final txt = pickText(tr).text;
  var hs = trap(f.lineH, 0.012, 0.03, 0.08, 0.15);
  if (ctx.hMed > 0) {
    final rel = f.lineH / ctx.hMed;
    hs = hs > 0 ? math.min(hs, 0.3 + 0.7 * trap(rel, 0.45, 0.8, 1.25, 2.0)) : 0.0;
  }
  final cs = 1 - math.min(1.0, (f.cx - 0.5).abs() / 0.35);
  final ts = textScore(txt);
  final os = f.outline < 0 ? 0.5 : trap(f.outline, 0.15, 0.5, 1.01, 2.0);
  final ls = laneScore(ctx, f.cy);
  final ds = durationScore(f.dur, f.n);
  var s = 0.17 * hs + 0.08 * cs + 0.25 * ts + 0.15 * os + 0.12 * ls + 0.13 * ds + 0.10 * 0.5;
  if (f.n == 1 && s < 0.7) s = math.min(s, kLikely - 0.01);
  return s;
}

int classify(double s) => s >= kLikely ? clsLikely : (s >= kDoubt ? clsDoubt : clsNon);

// ----------------------- hasil: Sub -----------------------
class Sub {
  double start;
  double end;
  String text;
  List<String> warn; // kode peringatan, lihat warnLabel di main.dart
  int cls;
  double score;
  int area;
  List<double>? box; // l,t,r,b (0..1)
  int n;
  String? alt;
  double? origStart;
  double? origEnd;
  String? refText;
  double? refStart;
  double? refEnd;
  double pair;
  double bonus; // koreksi skor dari subtitle referensi (+ didukung, - tidak didukung)
  bool accepted;
  Sub(this.start, this.end, this.text, [List<String>? warn])
      : warn = warn ?? <String>[],
        cls = clsLikely,
        score = 1.0,
        area = 0,
        n = 1,
        pair = -1.0,
        bonus = 0.0,
        accepted = false;

  double get eff => score + bonus;
  bool get exportable => text.trim().isNotEmpty && (cls == clsLikely || accepted);

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'text': text,
        'warn': warn,
        'cls': cls,
        'score': score,
        'area': area,
        'box': box,
        'n': n,
        'alt': alt,
        'os': origStart,
        'oe': origEnd,
        'rt': refText,
        'rs': refStart,
        're': refEnd,
        'pair': pair,
        'bo': bonus,
        'acc': accepted,
      };

  factory Sub.fromJson(Map<String, dynamic> j) {
    final s = Sub((j['start'] as num).toDouble(), (j['end'] as num).toDouble(), j['text'] as String,
        (j['warn'] as List?)?.map((e) => e.toString()).toList());
    s.cls = (j['cls'] as num?)?.toInt() ?? clsLikely;
    s.score = (j['score'] as num?)?.toDouble() ?? 1.0;
    s.area = (j['area'] as num?)?.toInt() ?? 0;
    s.box = (j['box'] as List?)?.map((e) => (e as num).toDouble()).toList();
    s.n = (j['n'] as num?)?.toInt() ?? 1;
    s.alt = j['alt'] as String?;
    s.origStart = (j['os'] as num?)?.toDouble();
    s.origEnd = (j['oe'] as num?)?.toDouble();
    s.refText = j['rt'] as String?;
    s.refStart = (j['rs'] as num?)?.toDouble();
    s.refEnd = (j['re'] as num?)?.toDouble();
    s.pair = (j['pair'] as num?)?.toDouble() ?? -1.0;
    s.bonus = (j['bo'] as num?)?.toDouble() ?? 0.0;
    s.accepted = (j['acc'] as bool?) ?? false;
    return s;
  }
}

/// Satu area -> daftar Sub (semua kelas, termasuk yang diragukan).
List<Sub> tracksToSubs(List<Track> tracks, double interval, {int area = 0, Ctx? ctx}) {
  final c = ctx ?? buildCtx(tracks, interval);
  final subs = <Sub>[];
  for (final tr in tracks) {
    final p = pickText(tr);
    final sc = scoreTrack(tr, c, interval);
    final s = Sub(math.max(0.0, tr.first - interval / 2), tr.last + interval / 2, p.text);
    s.area = area;
    s.score = sc;
    s.cls = classify(sc);
    s.alt = p.alt;
    s.n = tr.n;
    var l = tr.blocks.first.l, t = tr.blocks.first.t, r = tr.blocks.first.r, b = tr.blocks.first.b;
    for (final bl in tr.blocks) {
      l = math.min(l, bl.l);
      t = math.min(t, bl.t);
      r = math.max(r, bl.r);
      b = math.max(b, bl.b);
    }
    s.box = [l, t, r, b];
    if (p.tag != null) s.warn.add(p.tag!);
    if (tr.n == 1) s.warn.add('single');
    final lc = letterCount(p.text);
    final cc = p.text.replaceAll(RegExp(r'\s'), '').length;
    if (lc < 4) s.warn.add('short');
    if (cc > 0 && lc / cc < 0.7) s.warn.add('weird');
    if (s.cls == clsDoubt) s.warn.add('lowconf');
    subs.add(s);
  }
  for (final s in subs) {
    if (s.end - s.start < kMinDuration) {
      s.end = s.start + kMinDuration;
      s.warn.add('dur_short');
    }
    if (s.end - s.start > 8) s.warn.add('dur_long');
  }
  fixOverlaps(subs);
  return subs;
}

/// Perbaiki tumpang tindih hanya untuk subtitle di lajur yang sama (dua subtitle di posisi berbeda boleh tampil bersamaan).
void fixOverlaps(List<Sub> subs) {
  final lanes = <String, List<Sub>>{};
  final sorted = [...subs]..sort((a, b) => a.start.compareTo(b.start));
  for (final s in sorted) {
    final bx = s.box;
    final cy = bx == null ? 0.9 : (bx[1] + bx[3]) / 2;
    final key = '${s.area}:${(cy / 0.08).floor()}';
    lanes.putIfAbsent(key, () => <Sub>[]).add(s);
  }
  for (final lst in lanes.values) {
    for (var i = 0; i + 1 < lst.length; i++) {
      if (lst[i].end > lst[i + 1].start) {
        lst[i].end = math.max(lst[i].start + 0.1, lst[i + 1].start - 0.001);
      }
    }
  }
}
// ----------------------- koreksi otomatis (kamus dari hasil sendiri) -----------------------
final RegExp wordRe = RegExp(r'[A-Za-z0-9]+');

String canon(String w) {
  var s = w.toLowerCase().replaceAll('rn', 'm').replaceAll('vv', 'w');
  s = s.replaceAll(RegExp(r'[l1]'), 'i').replaceAll('0', 'o');
  return s;
}

String matchCase(String orig, String fixed) {
  if (orig.length > 1 && orig == orig.toUpperCase()) return fixed.toUpperCase();
  if (orig.isNotEmpty && orig[0] == orig[0].toUpperCase() && orig[0] != orig[0].toLowerCase()) {
    return fixed[0].toUpperCase() + fixed.substring(1);
  }
  return fixed;
}

/// Kata langka yang hanya beda huruf mirip (l/I/1, 0/O, rn/m) dari kata yang sering muncul.
Map<String, String> buildFixes(List<Sub> subs) {
  final freq = <String, int>{};
  for (final s in subs) {
    for (final m in wordRe.allMatches(s.text)) {
      final w = m.group(0)!.toLowerCase();
      freq[w] = (freq[w] ?? 0) + 1;
    }
  }
  final best = <String, String>{};
  for (final e in freq.entries) {
    if (e.value >= 3 && e.key.length >= 3) {
      final c = canon(e.key);
      final cur = best[c];
      if (cur == null || (freq[cur] ?? 0) < e.value) best[c] = e.key;
    }
  }
  final fixes = <String, String>{};
  for (final e in freq.entries) {
    if (e.key.length < 3 || e.value > 2) continue;
    final b = best[canon(e.key)];
    if (b != null && b != e.key && (freq[b] ?? 0) >= e.value * 3) fixes[e.key] = b;
  }
  return fixes;
}

// ----------------------- SRT: baca & tulis -----------------------
class Cue {
  final double start;
  final double end;
  final String text;
  Cue(this.start, this.end, this.text);
}

final RegExp _srtTime = RegExp(r'(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})');

/// Baca isi file .srt (toleran: BOM, CRLF, tag <i>, tag ASS {\an8}).
List<Cue> parseSrtFile(String src) {
  final s = src.replaceAll(String.fromCharCode(0xFEFF), '').replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  final cues = <Cue>[];
  for (final block in s.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    int idx = -1;
    RegExpMatch? m;
    for (var i = 0; i < lines.length; i++) {
      m = _srtTime.firstMatch(lines[i]);
      if (m != null) {
        idx = i;
        break;
      }
    }
    if (idx < 0 || m == null) continue;
    int g(int k) => int.parse(m!.group(k)!);
    int ms(int k) => int.parse(m!.group(k)!.padRight(3, '0'));
    final st = g(1) * 3600 + g(2) * 60 + g(3) + ms(4) / 1000;
    final en = g(5) * 3600 + g(6) * 60 + g(7) + ms(8) / 1000;
    var text = lines.sublist(idx + 1).join('\n');
    text = text.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\{\\[^}]*\}'), '');
    text = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
    if (text.isNotEmpty && en > st) cues.add(Cue(st, en, text));
  }
  cues.sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

/// Baca file .ass/.ssa (baris Dialogue). Gambar vektor (\p1) dilewati; tag {..} dibuang.
List<Cue> parseAssFile(String src) {
  final s = src.replaceAll(String.fromCharCode(0xFEFF), '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  var inEvents = false;
  var nFmt = 0, iS = -1, iE = -1, iT = -1;
  final cues = <Cue>[];
  final timeRe = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})[.,](\d{1,3})$');
  double? tm(String x) {
    final m = timeRe.firstMatch(x.trim());
    if (m == null) return null;
    final frac = int.parse(m.group(4)!.padRight(3, '0'));
    return int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!) + frac / 1000;
  }

  for (final line in s.split('\n')) {
    final t = line.trim();
    if (t.startsWith('[')) {
      inEvents = t.toLowerCase() == '[events]';
      continue;
    }
    if (!inEvents) continue;
    final low = t.toLowerCase();
    if (low.startsWith('format:')) {
      final f = t.substring(7).split(',').map((e) => e.trim().toLowerCase()).toList();
      nFmt = f.length;
      iS = f.indexOf('start');
      iE = f.indexOf('end');
      iT = f.indexOf('text');
      continue;
    }
    if (!low.startsWith('dialogue:') || iS < 0 || iE < 0 || iT < 0 || nFmt == 0) continue;
    var body = t.substring(9).trimLeft();
    final parts = <String>[];
    while (parts.length < nFmt - 1) {
      final k = body.indexOf(',');
      if (k < 0) break;
      parts.add(body.substring(0, k));
      body = body.substring(k + 1);
    }
    parts.add(body);
    if (parts.length != nFmt) continue;
    final st = tm(parts[iS]);
    final en = tm(parts[iE]);
    if (st == null || en == null || en <= st) continue;
    var text = parts[iT];
    if (RegExp(r'\\p[1-9]').hasMatch(text)) continue;
    text = text.replaceAll(RegExp(r'\{[^}]*\}'), '').replaceAll('\\N', '\n').replaceAll('\\n', '\n').replaceAll('\\h', ' ');
    text = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
    if (text.isNotEmpty) cues.add(Cue(st, en, text));
  }
  cues.sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

/// Baca subtitle referensi: otomatis mengenali ASS/SSA atau SRT.
List<Cue> parseReference(String src) {
  if (src.contains('[Events]') || RegExp(r'^\s*Dialogue:', multiLine: true).hasMatch(src)) return parseAssFile(src);
  return parseSrtFile(src);
}

/// SRT. Hanya kelas "kemungkinan subtitle" dan yang sudah diterima pengguna; `includeDoubtful` menambah yang meragukan.
String buildSrt(List<Sub> subs, {bool includeDoubtful = false}) {
  final sorted = [...subs]..sort((a, b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : a.area.compareTo(b.area);
    });
  final b = StringBuffer();
  var n = 0;
  for (final s in sorted) {
    final ok = s.exportable || (includeDoubtful && s.cls == clsDoubt && s.text.trim().isNotEmpty);
    if (!ok) continue;
    n++;
    b.write('$n\r\n${fmtSrt(s.start)} --> ${fmtSrt(s.end)}\r\n${s.text.trim().replaceAll('\n', '\r\n')}\r\n\r\n');
  }
  return b.toString();
}

String _assTime(double t) {
  var cs = (math.max(0.0, t) * 100).round();
  final h = cs ~/ 360000;
  cs %= 360000;
  final m = cs ~/ 6000;
  cs %= 6000;
  final s = cs ~/ 100;
  cs %= 100;
  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
}

String _assEscape(String t) => t.replaceAll('\\', '/').replaceAll('{', '(').replaceAll('}', ')').replaceAll('\r', '').replaceAll('\n', '\\N');

/// Lajur posisi: 0 atas, 1 tengah, 2 bawah (dari kotak subtitle).
int assLane(Sub s) {
  final bx = s.box;
  if (bx == null || bx.length != 4) return 2;
  final cy = (bx[1] + bx[3]) / 2;
  return cy < 0.33 ? 0 : (cy < 0.66 ? 1 : 2);
}

double _medianOf(List<double> v, double def) {
  if (v.isEmpty) return def;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

/// ASS dengan UKURAN HURUF TETAP dan posisi tetap per lajur (atas / tengah / bawah): tanpa \pos per baris,
/// jadi semua subtitle di lajur yang sama persis sama. `fontPx` null = ukuran otomatis (median tinggi huruf video).
String buildAss(List<Sub> subs, {required int width, required int height, bool includeDoubtful = false, double? fontPx}) {
  final w = width > 0 ? width : 1280;
  final h = height > 0 ? height : 720;
  final list = subs.where((s) => s.exportable || (includeDoubtful && s.cls == clsDoubt && s.text.trim().isNotEmpty)).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  // ukuran huruf: median dari semua subtitle (stabil terhadap kotak yang kurang tepat)
  final sizes = <double>[];
  for (final s in list) {
    final bx = s.box;
    if (bx != null && bx.length == 4) {
      final lines = math.max(1, s.text.trim().split('\n').length);
      sizes.add((bx[3] - bx[1]) * h / lines * 0.8);
    }
  }
  final fs = (fontPx ?? math.max(h * 0.035, math.min(h * 0.075, _medianOf(sizes, h * 0.055)))).round();
  // margin per lajur: median jarak ke tepi layar
  final marg = <int, List<double>>{0: <double>[], 1: <double>[], 2: <double>[]};
  for (final s in list) {
    final bx = s.box;
    if (bx == null || bx.length != 4) continue;
    final ln = assLane(s);
    if (ln == 0) marg[0]!.add(bx[1] * h);
    if (ln == 2) marg[2]!.add((1 - bx[3]) * h);
  }
  final used = <int>{for (final s in list) assLane(s)}.toList()..sort();
  if (used.isEmpty) used.add(2);
  const names = ['Atas', 'Tengah', 'Bawah'];
  const aligns = [8, 5, 2];
  final b = StringBuffer();
  b.write('[Script Info]\r\nTitle: Hardsub OCR\r\nScriptType: v4.00+\r\nWrapStyle: 2\r\nScaledBorderAndShadow: yes\r\n');
  b.write('PlayResX: $w\r\nPlayResY: $h\r\n\r\n');
  b.write('[V4+ Styles]\r\n');
  b.write('Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
      'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\n');
  for (final ln in used) {
    final mv = ln == 1 ? 0 : math.max(0, math.min((h * 0.4).round(), _medianOf(marg[ln]!, h * 0.04).round()));
    b.write('Style: ${names[ln]},Arial,$fs,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,${aligns[ln]},20,20,$mv,1\r\n');
  }
  b.write('\r\n[Events]\r\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n');
  for (final s in list) {
    b.write('Dialogue: ${s.area},${_assTime(s.start)},${_assTime(s.end)},${names[assLane(s)]},,0,0,0,,${_assEscape(s.text.trim())}\r\n');
  }
  return b.toString();
}

// ----------------------- watermark & tulisan menempel -----------------------
final RegExp _domainRe = RegExp(r'(?:www\.)?[A-Za-z0-9-]{5,}\.[a-z]{2,4}\b');

class Stripped {
  final String text;
  final double cutL; // porsi lebar yang dibuang di kiri
  final double cutR; // porsi lebar yang dibuang di kanan
  Stripped(this.text, this.cutL, this.cutR);
}

/// Buang alamat web (mis. "rajanime.com", termasuk salah baca "rajanime.cet") dari satu baris.
Stripped stripDomains(String text) {
  if (!_domainRe.hasMatch(text)) return Stripped(text, 0, 0);
  final total = math.max(1, text.length);
  final ms = _domainRe.allMatches(text).toList();
  var cutL = 0.0, cutR = 0.0;
  for (final m in ms) {
    if (m.start <= 1) cutL += (m.end - m.start) / total;
    if (m.end >= text.length - 1) cutR += (m.end - m.start) / total;
  }
  final out = text.replaceAll(_domainRe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return Stripped(out, cutL, cutR);
}

bool _plainLower(String t) => RegExp(r'^[a-z]+$').hasMatch(t);

/// Buang tulisan kecil yang diam di tepi layar (logo/watermark) dan muncul di sangat banyak sampel,
/// walau hasil bacanya berubah-ubah ("rajanime.com", "raiante. Cet", ...). Subtitle di tengah layar tidak tersentuh.
int stripStaticEdge(List<Sample> samples) {
  var nonEmpty = 0;
  for (final s in samples) {
    if (s.cands.isNotEmpty) nonEmpty++;
  }
  if (nonEmpty < 20) return 0;
  bool edgeSmall(Cand c) {
    final cx = (c.l + c.r) / 2;
    final cy = (c.t + c.b) / 2;
    return c.h <= 0.035 && (cx < 0.2 || cx > 0.8 || cy < 0.07 || cy > 0.95);
  }

  String key(Cand c) => '${(((c.l + c.r) / 2) / 0.08).floor()}:${(((c.t + c.b) / 2) / 0.08).floor()}';
  final counts = <String, int>{};
  for (final s in samples) {
    final seen = <String>{};
    for (final c in s.cands) {
      if (edgeSmall(c)) seen.add(key(c));
    }
    for (final k in seen) {
      counts[k] = (counts[k] ?? 0) + 1;
    }
  }
  final need = math.max(15.0, 0.25 * nonEmpty);
  final bad = <String>{for (final e in counts.entries) if (e.value >= need) e.key};
  if (bad.isEmpty) return 0;
  var removed = 0;
  for (final s in samples) {
    final keep = <Cand>[];
    for (final c in s.cands) {
      if (edgeSmall(c) && bad.contains(key(c))) {
        removed++;
      } else {
        keep.add(c);
      }
    }
    if (keep.length != s.cands.length) s.cands = keep;
  }
  return removed;
}

/// Hapus watermark dari semua sampel (mengubah in place): (1) pola alamat web, (2) token tak-biasa
/// (HURUF BESAR / berangka / bertitik) yang selalu menempel di ujung baris pada banyak kalimat berbeda.
/// Kata biasa (huruf kecil) tidak pernah dihapus oleh langkah (2). Mengembalikan jumlah baris yang diubah.
int stripOverlays(List<Sample> samples) {
  var changed = stripStaticEdge(samples);
  void shrink(Cand c, double cutL, double cutR) {
    final w = c.w;
    c.l += w * cutL;
    c.r -= w * cutR;
  }

  // (1) alamat web
  for (final s in samples) {
    final keep = <Cand>[];
    for (final c in s.cands) {
      final st = stripDomains(c.text);
      if (st.text != c.text) {
        changed++;
        c.text = st.text;
        shrink(c, st.cutL, st.cutR);
      }
      if (letterCount(c.text) >= 1) keep.add(c);
    }
    if (keep.length != s.cands.length) s.cands = keep;
  }
  // (2) token tak-biasa yang selalu di ujung baris
  final occ = <String, int>{};
  final edge = <String, int>{};
  final lines = <String, Set<String>>{};
  final seenLine = <String>{};
  for (final s in samples) {
    for (final c in s.cands) {
      final full = norm(c.text);
      if (!seenLine.add(full)) continue; // tiap teks baris unik dihitung sekali
      final toks = c.text.split(' ').where((e) => e.isNotEmpty).toList();
      for (var i = 0; i < toks.length; i++) {
        final n = norm(toks[i]);
        if (n.length < 4) continue;
        occ[n] = (occ[n] ?? 0) + 1;
        if (i == 0 || i == toks.length - 1) edge[n] = (edge[n] ?? 0) + 1;
        lines.putIfAbsent(n, () => <String>{}).add(full);
      }
    }
  }
  final bad = <String>{};
  for (final n in occ.keys) {
    final o = occ[n]!;
    if (o < 8 || (edge[n] ?? 0) / o < 0.85) continue;
    bad.add(n);
  }
  if (bad.isEmpty) return changed;
  bool isBadTok(String t) {
    final n = norm(t);
    if (!bad.contains(n)) return false;
    final letters = t.replaceAll(RegExp(r'[^A-Za-z]'), '');
    final unusual = !_plainLower(letters) || RegExp(r'[0-9.@]').hasMatch(t);
    return unusual && (letters.toUpperCase() == letters || RegExp(r'[0-9.@]').hasMatch(t));
  }

  for (final s in samples) {
    final keep = <Cand>[];
    for (final c in s.cands) {
      final toks = c.text.split(' ').where((e) => e.isNotEmpty).toList();
      if (toks.isNotEmpty && (isBadTok(toks.first) || isBadTok(toks.last)) && toks.length > 1) {
        final total = math.max(1, c.text.length);
        var cutL = 0.0, cutR = 0.0;
        if (isBadTok(toks.last)) {
          cutR = toks.last.length / total;
          toks.removeLast();
        }
        if (toks.isNotEmpty && isBadTok(toks.first)) {
          cutL = toks.first.length / total;
          toks.removeAt(0);
        }
        c.text = toks.join(' ');
        shrink(c, cutL, cutR);
        changed++;
      } else if (toks.length == 1 && isBadTok(toks.first)) {
        changed++;
        continue; // baris yang hanya berisi watermark
      }
      if (letterCount(c.text) >= 1) keep.add(c);
    }
    if (keep.length != s.cands.length) s.cands = keep;
  }
  return changed;
}

// ----------------------- pencocokan dengan subtitle referensi -----------------------
class OffsetInfo {
  final double offset; // waktu_ref = waktu_ocr + offset
  final double score;
  final double median;
  final double frac; // porsi subtitle OCR yang awalnya cocok dalam 1 dtk dengan cue referensi
  final bool ok;
  OffsetInfo(this.offset, this.score, this.median, this.frac, this.ok);
}

int _lowerBound(List<double> a, double x) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (a[mid] < x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

double _nearest(List<double> a, double x) {
  final i = _lowerBound(a, x);
  var best = 1e9;
  if (i < a.length) best = math.min(best, (a[i] - x).abs());
  if (i > 0) best = math.min(best, (a[i - 1] - x).abs());
  return best;
}

/// Perkiraan geser global memakai waktu mulai/akhir saja (bahasa berbeda, jadi teks tidak dibandingkan).
OffsetInfo? estimateOffset(List<Sub> subs, List<Cue> cues, {double lo = -90.0, double hi = 90.0}) {
  final items = subs.where((s) => s.cls == clsLikely || s.cls == clsDoubt).toList();
  if (items.length < 3 || cues.length < 3) return null;
  final rs = cues.map((c) => c.start).toList()..sort();
  final re = cues.map((c) => c.end).toList()..sort();
  const sig = 0.5;
  double score(double d) {
    var sc = 0.0;
    for (final s in items) {
      final a = _nearest(rs, s.start + d);
      final b = _nearest(re, s.end + d);
      sc += math.exp(-a * a / (2 * sig * sig)) + 0.5 * math.exp(-b * b / (2 * sig * sig));
    }
    return sc;
  }

  final n = ((hi - lo) / 0.1).round();
  final vals = <double>[];
  var bi = 0;
  for (var i = 0; i <= n; i++) {
    final v = score(lo + i * 0.1);
    vals.add(v);
    if (v > vals[bi]) bi = i;
  }
  var bestD = lo + bi * 0.1;
  var bestS = -1.0;
  final c0 = bestD;
  for (var k = -5; k <= 5; k++) {
    final d = c0 + k * 0.02;
    final v = score(d);
    if (v > bestS) {
      bestS = v;
      bestD = d;
    }
  }
  final sortedVals = [...vals]..sort();
  final med = sortedVals[sortedVals.length ~/ 2];
  var matched = 0;
  for (final s in items) {
    if (_nearest(rs, s.start + bestD) <= 1.0) matched++;
  }
  final frac = matched / items.length;
  return OffsetInfo(bestD, bestS, med, frac, frac >= 0.4 && bestS >= 2.0 * math.max(med, 1e-9));
}

double _lenScore(int lo, int lr) {
  if (lo <= 0 || lr <= 0) return 0.3;
  final r = lo / lr;
  return math.max(0.0, 1.0 - math.min(1.0, (math.log(r / 1.1)).abs() / math.log(2.5)));
}

double pairScore(double os, double oe, int olen, double rs, double re, int rlen, double off) {
  final s0 = os + off;
  final e0 = oe + off;
  final ds = (s0 - rs).abs();
  final de = (e0 - re).abs();
  final ov = math.min(e0, re) - math.max(s0, rs);
  final union = math.max(e0, re) - math.min(s0, rs);
  final iou = union > 0 ? math.max(0.0, ov) / union : 0.0;
  final t = 0.5 * math.max(0.0, 1 - ds / 3.0) + 0.2 * math.max(0.0, 1 - de / 3.0) + 0.3 * iou;
  final durO = math.max(0.01, oe - os);
  final durR = math.max(0.01, re - rs);
  final d = math.min(durO, durR) / math.max(durO, durR);
  return 0.65 * t + 0.10 * d + 0.25 * _lenScore(olen, rlen);
}

const double _theta = 0.42;
const double _band = 8.0;

class Pairing {
  final int kind; // 11, 12 (satu OCR - dua ref), 21 (dua OCR - satu ref)
  final int i; // indeks di daftar OCR yang ikut
  final int j; // indeks cue
  Pairing(this.kind, this.i, this.j);
}

/// Pencocokan urutan (DP mirip Gale-Church): tahan terhadap dialog hilang, terpisah, atau tergabung.
List<Pairing> alignSequences(List<Sub> items, List<Cue> cues, List<double> offs) {
  final n = items.length;
  final m = cues.length;
  final oPre = List<int>.filled(n + 1, 0);
  for (var k = 0; k < n; k++) {
    oPre[k + 1] = oPre[k] + norm(items[k].text).length;
  }
  final rPre = List<int>.filled(m + 1, 0);
  for (var k = 0; k < m; k++) {
    rPre[k + 1] = rPre[k] + norm(cues[k].text).length;
  }
  double? g11(int i, int j) {
    final s = items[i];
    final c = cues[j];
    if ((s.start + offs[i] - c.start).abs() > _band) return null;
    return pairScore(s.start, s.end, oPre[i + 1] - oPre[i], c.start, c.end, rPre[j + 1] - rPre[j], offs[i]) - _theta;
  }

  double? g12(int i, int j) {
    if (j + 1 >= m) return null;
    final s = items[i];
    final c0 = cues[j];
    final c1 = cues[j + 1];
    if (c1.start - c0.end > 2.5) return null;
    if ((s.start + offs[i] - c0.start).abs() > _band) return null;
    return pairScore(s.start, s.end, oPre[i + 1] - oPre[i], c0.start, c1.end, rPre[j + 2] - rPre[j], offs[i]) - _theta - 0.08;
  }

  double? g21(int i, int j) {
    if (i + 1 >= n) return null;
    final s0 = items[i];
    final s1 = items[i + 1];
    if (s1.start - s0.end > 2.5) return null;
    final c = cues[j];
    if ((s0.start + offs[i] - c.start).abs() > _band) return null;
    return pairScore(s0.start, s1.end, oPre[i + 2] - oPre[i], c.start, c.end, rPre[j + 1] - rPre[j], offs[i]) - _theta - 0.08;
  }

  const neg = -1e18;
  final d = List<List<double>>.generate(n + 1, (_) => List<double>.filled(m + 1, neg));
  // gerakan: 1 lewati OCR, 2 lewati ref, 3 = 1-1, 4 = 1-2, 5 = 2-1
  final back = List<List<int>>.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  d[0][0] = 0.0;
  for (var i = 0; i <= n; i++) {
    for (var j = 0; j <= m; j++) {
      final cur = d[i][j];
      if (cur <= neg / 2) continue;
      if (i < n && cur > d[i + 1][j]) {
        d[i + 1][j] = cur;
        back[i + 1][j] = 1;
      }
      if (j < m && cur > d[i][j + 1]) {
        d[i][j + 1] = cur;
        back[i][j + 1] = 2;
      }
      if (i < n && j < m) {
        final g = g11(i, j);
        if (g != null && g > 0 && cur + g > d[i + 1][j + 1]) {
          d[i + 1][j + 1] = cur + g;
          back[i + 1][j + 1] = 3;
        }
      }
      if (i < n && j + 1 < m) {
        final g = g12(i, j);
        if (g != null && g > 0 && cur + g > d[i + 1][j + 2]) {
          d[i + 1][j + 2] = cur + g;
          back[i + 1][j + 2] = 4;
        }
      }
      if (i + 1 < n && j < m) {
        final g = g21(i, j);
        if (g != null && g > 0 && cur + g > d[i + 2][j + 1]) {
          d[i + 2][j + 1] = cur + g;
          back[i + 2][j + 1] = 5;
        }
      }
    }
  }
  final res = <Pairing>[];
  var i = n, j = m;
  while (i > 0 || j > 0) {
    final mv = back[i][j];
    if (mv == 1) {
      i -= 1;
    } else if (mv == 2) {
      j -= 1;
    } else if (mv == 3) {
      i -= 1;
      j -= 1;
      res.add(Pairing(11, i, j));
    } else if (mv == 4) {
      i -= 1;
      j -= 2;
      res.add(Pairing(12, i, j));
    } else if (mv == 5) {
      i -= 2;
      j -= 1;
      res.add(Pairing(21, i, j));
    } else {
      break; // tidak seharusnya terjadi
    }
  }
  return res.reversed.toList();
}

double _median(List<double> v) {
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

class MatchResult {
  final OffsetInfo? info;
  final List<Pairing> pairs;
  final List<double> offs;
  final List<int> idx; // indeks ke daftar subs yang diikutkan
  MatchResult(this.info, this.pairs, this.offs, this.idx);
  double get driftMin => offs.isEmpty ? 0 : offs.reduce(math.min);
  double get driftMax => offs.isEmpty ? 0 : offs.reduce(math.max);
}

MatchResult matchReference(List<Sub> subs, List<Cue> cues) {
  final info = estimateOffset(subs, cues);
  if (info == null) return MatchResult(null, [], [], []);
  final idx = <int>[];
  for (var i = 0; i < subs.length; i++) {
    if (subs[i].cls == clsLikely || subs[i].cls == clsDoubt) idx.add(i);
  }
  idx.sort((a, b) => subs[a].start.compareTo(subs[b].start));
  final items = idx.map((i) => subs[i]).toList();
  var offs = List<double>.filled(items.length, info.offset);
  var pairs = <Pairing>[];
  for (var it = 0; it < 3; it++) {
    pairs = alignSequences(items, cues, offs);
    final pts = <List<double>>[];
    for (final p in pairs) {
      if (p.kind != 11) continue;
      final s = items[p.i];
      final c = cues[p.j];
      if (pairScore(s.start, s.end, norm(s.text).length, c.start, c.end, norm(c.text).length, offs[p.i]) >= 0.7) {
        pts.add([p.i.toDouble(), c.start - s.start]);
      }
    }
    if (pts.length < 3) break;
    final next = <double>[];
    for (var k = 0; k < items.length; k++) {
      final near = [...pts]..sort((a, b) => (a[0] - k).abs().compareTo((b[0] - k).abs()));
      final d = _median(near.take(5).map((e) => e[1]).toList());
      next.add(math.max(info.offset - 20, math.min(info.offset + 20, d)));
    }
    var maxDiff = 0.0;
    for (var k = 0; k < next.length; k++) {
      maxDiff = math.max(maxDiff, (next[k] - offs[k]).abs());
    }
    offs = next;
    if (maxDiff < 0.05) break;
  }
  return MatchResult(info, pairs, offs, idx);
}

/// Batalkan penerapan referensi sebelumnya (waktu asli kembali, cue "tanpa OCR" dihapus). Panggil sebelum matchReference.
void clearReference(List<Sub> subs) {
  subs.removeWhere((s) => s.cls == clsMissing && !s.accepted);
  for (final s in subs) {
    if (s.origStart != null && s.origEnd != null) {
      s.start = s.origStart!;
      s.end = s.origEnd!;
    }
    s.origStart = null;
    s.origEnd = null;
    s.refText = null;
    s.refStart = null;
    s.refEnd = null;
    s.pair = -1.0;
    s.bonus = 0.0;
    s.warn.removeWhere((w) => const ['split2', 'span2', 'lowpair', 'trunc_ref', 'conflict', 'bigshift', 'noref'].contains(w));
    if (!s.accepted && s.cls != clsMissing) s.cls = classify(s.score);
  }
}

class ApplyStats {
  int confident = 0;
  int probable = 0;
  int unmatched = 0;
  int missing = 0;
}

/// Terapkan hasil pencocokan (panggil clearReference lebih dulu). timeline 0 = ikuti waktu referensi, 1 = tetap garis waktu video (waktu OCR dirapikan oleh referensi).
/// Koreksi waktu HANYA untuk pasangan yang yakin dan jika kedua sumber tervalidasi sebagai versi video yang sama.
ApplyStats applyReference(List<Sub> subs, List<Cue> cues, MatchResult r, {int timeline = 0, double? covLo, double? covHi}) {
  final st = ApplyStats();
  final info = r.info;
  if (info == null) return st;
  final items = r.idx.map((i) => subs[i]).toList();
  final offs = r.offs;
  final validated = info.ok;
  final matchedOcr = <int>{};
  final matchedRef = <int>{};
  double tOf(double refTime, double off) => timeline == 0 ? refTime : refTime - off;

  for (final p in r.pairs) {
    final go = p.kind == 21 ? [p.i, p.i + 1] : [p.i];
    final gr = p.kind == 12 ? [p.j, p.j + 1] : [p.j];
    final first = items[go.first];
    final lastO = items[go.last];
    var olen = 0;
    for (final k in go) {
      olen += norm(items[k].text).length;
    }
    var rlen = 0;
    for (final k in gr) {
      rlen += norm(cues[k].text).length;
    }
    final ps = pairScore(first.start, lastO.end, olen, cues[gr.first].start, cues[gr.last].end, rlen, offs[p.i]);
    final rs = cues[gr.first].start;
    final re = cues[gr.last].end;
    final rtxt = gr.map((k) => cues[k].text).join('\n');
    for (final k in go) {
      matchedOcr.add(r.idx[k]);
    }
    for (final k in gr) {
      matchedRef.add(k);
    }
    for (final k in go) {
      final s = items[k];
      s.pair = ps;
      s.refText = rtxt;
      s.refStart = rs;
      s.refEnd = re;
      s.origStart ??= s.start;
      s.origEnd ??= s.end;
    }
    final confident = ps >= 0.65 && validated;
    final off = offs[p.i];
    if (go.length == 2) {
      final a = items[go[0]];
      final b = items[go[1]];
      final la = math.max(1, norm(a.text).length);
      final lb = math.max(1, norm(b.text).length);
      final mid = rs + (re - rs) * la / (la + lb);
      if (confident) {
        a.start = tOf(rs, off);
        a.end = tOf(mid, off);
        b.start = tOf(mid, off);
        b.end = tOf(re, off);
      }
      a.warn.add('split2');
      b.warn.add('split2');
    } else if (gr.length == 2) {
      if (confident) {
        first.start = tOf(rs, off);
        first.end = tOf(re, off);
      }
      first.warn.add('span2');
    } else if (confident) {
      first.start = tOf(rs, off);
      first.end = tOf(re, off);
    }
    if (confident) {
      st.confident++;
    } else {
      st.probable++;
    }
    for (final k in go) {
      final s = items[k];
      final lr = norm(s.text).length / math.max(1, norm(s.refText ?? '').length);
      var odd = false;
      if (go.length == 1 && gr.length == 1) {
        if (lr < 0.5) {
          s.warn.add('trunc_ref');
          odd = true;
        }
        if (lr > 2.5 || lr < 0.3) {
          s.warn.add('conflict');
          odd = true;
        }
      }
      if (confident && !odd) {
        s.bonus = 0.25;
      } else if (ps >= 0.5 && !odd) {
        s.bonus = 0.05;
      }
      if (!s.accepted) s.cls = classify(s.eff);
      if (!confident) s.warn.add('lowpair');
      final os = s.origStart;
      if (os != null && (s.start - os - (timeline == 0 ? off : 0.0)).abs() > 1.5) s.warn.add('bigshift');
    }
  }
  for (var q = 0; q < r.idx.length; q++) {
    final k = r.idx[q];
    if (matchedOcr.contains(k)) continue;
    final s = subs[k];
    if (timeline == 0 && validated) {
      s.origStart ??= s.start;
      s.origEnd ??= s.end;
      s.start += offs[q];
      s.end += offs[q];
    }
    s.bonus = -0.1;
    if (!s.accepted) s.cls = classify(s.eff);
    s.warn.add('noref');
    st.unmatched++;
  }
  final lo = covLo ?? -1e9;
  final hi = covHi ?? 1e9;
  final missing = <Sub>[];
  for (var j = 0; j < cues.length; j++) {
    if (matchedRef.contains(j)) continue;
    final c = cues[j];
    if (!(c.start - info.offset >= lo && c.end - info.offset <= hi)) continue;
    final m = Sub(tOf(c.start, info.offset), tOf(c.end, info.offset), '', ['missing']);
    m.cls = clsMissing;
    m.refText = c.text;
    m.refStart = c.start;
    m.refEnd = c.end;
    m.score = 0.0;
    missing.add(m);
  }
  st.missing = missing.length;
  subs.addAll(missing);
  return st;
}

/// Dari beberapa hasil baca-ulang frame, ambil versi yang lebih lengkap dan konsisten dengan teks sekarang.
/// Hanya jika versi itu muncul >= 2 kali; tidak pernah mengarang bagian yang hilang.
String? pickRecovered(String current, List<String> options) {
  final cn = norm(current);
  final counts = <String, int>{};
  final reps = <String, String>{};
  for (final t in options) {
    final n = norm(t);
    if (n.isEmpty) continue;
    counts[n] = (counts[n] ?? 0) + 1;
    reps.putIfAbsent(n, () => t);
  }
  String? best;
  for (final e in counts.entries) {
    final n = e.key;
    if (n.length >= cn.length * 1.15 && containedIn(cn, n)) {
      final txt = reps[n]!;
      final lc = letterCount(txt);
      final cc = txt.replaceAll(RegExp(r'\s'), '').length;
      if (cc > 0 && lc / cc >= 0.8 && e.value >= 2) {
        if (best == null || e.value > counts[best]! || (e.value == counts[best]! && n.length > best.length)) best = n;
      }
    }
  }
  return best == null ? null : reps[best];
}
