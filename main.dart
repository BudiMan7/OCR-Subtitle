import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'algo.dart';

// =====================================================================
//  HARDSUB OCR → SRT/ASS
//  Alur: pilih video → atur area OCR → (opsional) SRT referensi Inggris
//        → OCR di HP (offline) → analisis & pencocokan → review → ekspor.
//  Semua algoritma ada di algo.dart (bisa dites); file ini = UI + OCR.
// =====================================================================

const double kChangeFrac = 0.0015; // perubahan piksel teks di bawah ini = frame dianggap sama
const double kMinTextFrac = 0.001; // minimal piksel teks agar dianggap ada subtitle
const int kSaveEvery = 100;
const int kMaxAreas = 3;
const int kWideId = 90; // id area sementara untuk baca-ulang frame

const MethodChannel _ch = MethodChannel('hardsub/native');

const Map<String, String> kWarn = {
  'single': 'hanya terbaca 1 kali',
  'short': 'teks sangat pendek',
  'weird': 'banyak karakter aneh',
  'dur_short': 'durasi sangat pendek',
  'dur_long': 'durasi panjang (>8 dtk)',
  'lowconf': 'keyakinan rendah (mungkin bukan subtitle)',
  'trunc': 'frame lain lebih panjang, mungkin terpotong',
  'trunc_ref': 'jauh lebih pendek dari teks referensi, mungkin terpotong',
  'conflict': 'bentrok dengan referensi (panjang sangat berbeda)',
  'noref': 'tidak ada pasangan di referensi',
  'lowpair': 'pasangan referensi kurang yakin',
  'split2': 'satu dialog referensi = 2 hasil OCR',
  'span2': 'satu hasil OCR = 2 dialog referensi',
  'bigshift': 'waktu bergeser >1,5 dtk dari hasil OCR',
  'missing': 'ada di referensi, tidak terbaca OCR',
  'recovered': 'hasil baca ulang, mohon dicek',
};

String warnLabel(String w) => kWarn[w] ?? w;

// ----------------------- model area & langkah -----------------------
/// Satu area OCR yang berdiri sendiri (kotak, jenis tulisan, dan riwayat teks sendiri).
class OcrArea {
  int id;
  bool enabled;
  bool full; // seluruh layar (posisi subtitle berpindah-pindah)
  double x0, x1, y0, y1;
  int script; // 0 Latin, 1 Jepang, 2 keduanya
  OcrArea(this.id, {this.enabled = true, this.full = true, this.x0 = 0.0, this.x1 = 1.0, this.y0 = 0.72, this.y1 = 0.97, this.script = 0});

  String get name => 'Area ${String.fromCharCode(65 + id)}';
  double get ex0 => full ? 0.0 : x0;
  double get ex1 => full ? 1.0 : x1;
  double get ey0 => full ? 0.0 : y0;
  double get ey1 => full ? 1.0 : y1;
  String get scriptName => const ['Latin', 'Jepang', 'Latin + Jepang'][script.clamp(0, 2).toInt()];
  String get sig =>
      '$id:${enabled ? 1 : 0}:${full ? 1 : 0}:${ex0.toStringAsFixed(2)},${ex1.toStringAsFixed(2)},${ey0.toStringAsFixed(2)},${ey1.toStringAsFixed(2)}:$script';

  Map<String, dynamic> toJson() => {'id': id, 'en': enabled, 'full': full, 'x0': x0, 'x1': x1, 'y0': y0, 'y1': y1, 'script': script};
  factory OcrArea.fromJson(Map<String, dynamic> j) {
    double d(dynamic v, double def) => v is num ? v.toDouble() : def;
    return OcrArea((j['id'] as num?)?.toInt() ?? 0,
        enabled: j['en'] is bool ? j['en'] as bool : true,
        full: j['full'] is bool ? j['full'] as bool : true,
        x0: d(j['x0'], 0.0),
        x1: d(j['x1'], 1.0),
        y0: d(j['y0'], 0.72),
        y1: d(j['y1'], 0.97),
        script: ((j['script'] as num?)?.toInt() ?? 0).clamp(0, 2).toInt());
  }
}

/// Hasil OCR semua area pada satu waktu.
class OcrStep {
  final double t;
  final Map<int, List<Cand>> c;
  OcrStep(this.t, this.c);
  Map<String, dynamic> toJson() => {
        't': t,
        'a': {for (final e in c.entries) '${e.key}': e.value.map((x) => x.toJson()).toList()},
      };
  factory OcrStep.fromJson(Map<String, dynamic> j) {
    final m = <int, List<Cand>>{};
    (j['a'] as Map<String, dynamic>).forEach((k, v) {
      m[int.parse(k)] = (v as List).map((e) => Cand.fromJson(e as Map<String, dynamic>)).toList();
    });
    return OcrStep((j['t'] as num).toDouble(), m);
  }
}

class _Ln {
  final String text;
  final Rect box; // piksel gambar yang dibaca
  final int src; // 0 gambar asli, 1 gambar hitam-putih
  _Ln(this.text, this.box, this.src);
}

class _Merge {
  final List<_Ln> lines;
  final bool changed;
  _Merge(this.lines, this.changed);
}

String _joined(List<Cand>? c) => (c ?? <Cand>[]).map((x) => x.text).join('\n');

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

  // ---- video ----
  String? uri;
  String name = '';
  int durMs = 0;
  int vw = 0, vh = 0;
  double previewT = 30;
  Uint8List? previewBytes;
  double previewAspect = 16 / 9;
  String? lastUri;
  String lastName = '';

  // ---- pengaturan (disimpan otomatis) ----
  List<OcrArea> areas = [OcrArea(0)];
  bool strictLatin = true; // area Latin: buang area yang dikenali sebagai tulisan Jepang
  bool light = true;
  double bright = 210;
  double interval = 0.33;
  bool adaptive = true;
  bool testMode = true;
  int quality = 1; // 0 cepat, 1 seimbang, 2 teliti (baca 2x)
  int refTimeline = 0; // 0 ikuti waktu referensi, 1 tetap garis waktu video
  double assPct = 0; // ukuran huruf ASS, % tinggi video (0 = otomatis)

  // ---- referensi ----
  List<Cue> refCues = [];
  String refName = '';
  String refStatus = '';
  double? refOffset;

  // ---- proses ----
  bool running = false;
  bool cancel = false;
  double progress = 0;
  String status = 'Belum mulai.';
  String testResult = '';
  List<OcrStep> steps = [];
  double covLo = 0, covHi = 0;

  // ---- hasil ----
  List<Sub> subs = [];
  int filter = 0;
  bool includeDoubtful = false;
  String filesDir = '';

  List<OcrArea> get _active => areas.where((a) => a.enabled).toList();

  // ===================== siklus hidup =====================
  @override
  void initState() {
    super.initState();
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
        final cov = j['cov'];
        if (cov is List && cov.length == 2) {
          covLo = (cov[0] as num).toDouble();
          covHi = (cov[1] as num).toDouble();
        }
        vw = (j['vw'] as num?)?.toInt() ?? vw;
        vh = (j['vh'] as num?)?.toInt() ?? vh;
        refOffset = (j['refOffset'] as num?)?.toDouble();
        refStatus = (j['refStatus'] as String?) ?? '';
      }
      final rf = File('$filesDir/ref.json');
      if (await rf.exists()) {
        final j = jsonDecode(await rf.readAsString()) as Map<String, dynamic>;
        refName = (j['name'] as String?) ?? '';
        refCues = (j['cues'] as List).map((e) {
          final l = e as List;
          return Cue((l[0] as num).toDouble(), (l[1] as num).toDouble(), l[2] as String);
        }).toList();
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

  // ===================== pengaturan tersimpan =====================
  double _d(dynamic v, double def) => v is num ? v.toDouble() : def;

  Future<void> _loadSettings() async {
    final f = File('$filesDir/settings.json');
    if (!await f.exists()) return;
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    if (j['areas'] is List && (j['areas'] as List).isNotEmpty) {
      areas = (j['areas'] as List).map((e) => OcrArea.fromJson(e as Map<String, dynamic>)).toList();
    } else if (j.containsKey('y0')) {
      // pengaturan versi lama: satu area
      areas = [
        OcrArea(0,
            full: j['autoPos'] is bool ? j['autoPos'] as bool : false,
            x0: _d(j['x0'], 0.0),
            x1: _d(j['x1'], 1.0),
            y0: _d(j['y0'], 0.72),
            y1: _d(j['y1'], 0.97),
            script: (j['script'] is int) ? (j['script'] as int).clamp(0, 2).toInt() : 0)
      ];
    }
    strictLatin = j['strictLatin'] is bool ? j['strictLatin'] as bool : strictLatin;
    light = j['light'] is bool ? j['light'] as bool : light;
    adaptive = j['adaptive'] is bool ? j['adaptive'] as bool : adaptive;
    testMode = j['testMode'] is bool ? j['testMode'] as bool : testMode;
    quality = (j['quality'] is int) ? (j['quality'] as int).clamp(0, 2).toInt() : quality;
    refTimeline = (j['refTimeline'] is int) ? (j['refTimeline'] as int).clamp(0, 1).toInt() : refTimeline;
    bright = _d(j['bright'], bright).clamp(120.0, 245.0).toDouble();
    assPct = _d(j['assPct'], 0.0).clamp(0.0, 9.0).toDouble();
    final iv = _d(j['interval'], interval);
    interval = (iv == 0.33 || iv == 0.5 || iv == 1.0) ? iv : 0.33;
    lastUri = j['lastUri'] as String?;
    lastName = (j['lastName'] as String?) ?? '';
  }

  Future<void> _persist() async {
    if (filesDir.isEmpty) return;
    try {
      await File('$filesDir/settings.json').writeAsString(jsonEncode({
        'areas': areas.map((a) => a.toJson()).toList(),
        'strictLatin': strictLatin,
        'light': light,
        'bright': bright,
        'interval': interval,
        'adaptive': adaptive,
        'testMode': testMode,
        'quality': quality,
        'refTimeline': refTimeline,
        'assPct': assPct,
        'lastUri': lastUri,
        'lastName': lastName,
      }));
    } catch (_) {}
  }

  void _set(VoidCallback f) {
    setState(f);
    _persist();
  }

  // ===================== video =====================
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
        steps = [];
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

  // ===================== referensi (SRT Inggris) =====================
  Future<void> pickRef() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('pickText');
      if (r == null) return;
      final cues = parseReference(r['text'] as String);
      if (cues.isEmpty) {
        _snack('File ini tidak berisi dialog SRT/ASS yang bisa dibaca.');
        return;
      }
      setState(() {
        refCues = cues;
        refName = r['name'] as String;
        refStatus = '';
      });
      try {
        await File('$filesDir/ref.json').writeAsString(jsonEncode({
          'name': refName,
          'cues': cues.map((c) => [c.start, c.end, c.text]).toList(),
        }));
      } catch (_) {}
      if (subs.isNotEmpty) {
        await _syncNow();
      } else {
        _snack('${cues.length} dialog referensi dimuat. Akan dipakai otomatis setelah OCR selesai.');
      }
    } catch (e) {
      _snack('Gagal membaca file: $e');
    }
  }

  Future<void> clearRef() async {
    setState(() {
      refCues = [];
      refName = '';
      refStatus = '';
      refOffset = null;
    });
    try {
      final f = File('$filesDir/ref.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    clearReference(subs);
    setState(() {});
    await saveSubs();
  }

  /// Cocokkan hasil OCR dengan referensi (mengubah `list`).
  void _applyRef(List<Sub> list) {
    clearReference(list);
    if (refCues.isEmpty) {
      refStatus = '';
      refOffset = null;
      return;
    }
    final r = matchReference(list, refCues);
    final info = r.info;
    if (info == null) {
      refStatus = 'Referensi: hasil OCR atau dialog referensi terlalu sedikit untuk dicocokkan.';
      refOffset = null;
      return;
    }
    final st = applyReference(list, refCues, r, timeline: refTimeline, covLo: covHi > covLo ? covLo : null, covHi: covHi > covLo ? covHi : null);
    refOffset = info.offset;
    final sign = info.offset >= 0 ? '+' : '';
    refStatus = 'Offset $sign${info.offset.toStringAsFixed(2)} dtk • ${(info.frac * 100).round()}% cocok • '
        '${info.ok ? 'kedua sumber tampak versi video yang sama' : 'TIDAK yakin sama versi: waktu TIDAK diubah, hanya ditandai'}\n'
        'Pasangan yakin ${st.confident}, ragu ${st.probable}, tanpa pasangan ${st.unmatched}, dialog referensi tanpa OCR ${st.missing} • '
        'geser lokal ${r.driftMin.toStringAsFixed(1)} s/d ${r.driftMax.toStringAsFixed(1)} dtk';
  }

  Future<void> _syncNow() async {
    if (refCues.isEmpty) {
      _snack('Pilih SRT referensi dulu.');
      return;
    }
    setState(() => status = 'Mencocokkan dengan referensi...');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    _applyRef(subs);
    setState(() => status = 'Pencocokan selesai.');
    await saveSubs();
  }

  // ===================== OCR =====================
  double _overlap(Rect a, Rect b) {
    if (!a.overlaps(b)) return 0;
    final i = a.intersect(b);
    final area = a.width * a.height;
    return area <= 0 ? 0 : (i.width * i.height) / area;
  }

  Future<List<_Ln>> _lines(OcrArea a, String path) async {
    final input = InputImage.fromFilePath(path);
    final out = <_Ln>[];
    if (a.script == 0) {
      final r = await _rec.processImage(input);
      for (final b in r.blocks) {
        for (final l in b.lines) {
          out.add(_Ln(l.text, l.boundingBox, 0));
        }
      }
      if (strictLatin && out.isNotEmpty) {
        // Pengenal Jepang hanya menandai area tulisan Jepang; area itu dibuang dari hasil Latin
        final rj = await _jp.processImage(input);
        final jpBoxes = <Rect>[];
        for (final b in rj.blocks) {
          for (final l in b.lines) {
            if (hasCjk(l.text)) jpBoxes.add(l.boundingBox);
          }
        }
        if (jpBoxes.isNotEmpty) {
          out.removeWhere((ln) => jpBoxes.any((jb) => _overlap(ln.box, jb) > 0.3));
        }
      }
    } else {
      final r = await _jp.processImage(input);
      for (final b in r.blocks) {
        for (final l in b.lines) {
          out.add(_Ln(l.text, l.boundingBox, 0));
        }
      }
    }
    return out;
  }

  List<_Ln> _cleanLines(List<_Ln> lines, int mode) {
    final out = <_Ln>[];
    for (final l in lines) {
      final t = cleanText(l.text, mode);
      if (t.isEmpty) continue;
      // buang alamat web/watermark (mis. rajanime.com) dari baris
      final st = stripDomains(t);
      if (st.text.isEmpty || letterCount(st.text) < 1) continue;
      var box = l.box;
      if (st.text != t) {
        box = Rect.fromLTRB(l.box.left + l.box.width * st.cutL, l.box.top, l.box.right - l.box.width * st.cutR, l.box.bottom);
      }
      out.add(_Ln(st.text, box, l.src));
    }
    return out;
  }

  /// Statistik kotak (porsi teks, tepi gelap, teks di sisi kiri/kanan) dari gambar abu-abu terakhir area ini.
  Future<List<Map<String, double>>> _stats(int id, List<_Ln> lines) async {
    final dflt = <Map<String, double>>[
      for (final _ in lines) {'fill': -1.0, 'outline': -1.0, 'extL': 0.0, 'extR': 0.0}
    ];
    if (lines.isEmpty) return dflt;
    try {
      final boxes = lines.map((l) => <double>[l.box.left, l.box.top, l.box.right, l.box.bottom]).toList();
      final res = await _ch.invokeMethod<List<dynamic>>('boxStats', {'id': id, 'boxes': boxes});
      if (res == null || res.length != lines.length) return dflt;
      return res.map((e) {
        final m = e as Map;
        return <String, double>{
          'fill': (m['fill'] as num).toDouble(),
          'outline': (m['outline'] as num).toDouble(),
          'extL': (m['extL'] as num).toDouble(),
          'extR': (m['extR'] as num).toDouble(),
        };
      }).toList();
    } catch (_) {
      return dflt;
    }
  }

  /// Gabungkan hasil gambar asli dan hitam-putih: pakai versi lebih lengkap (hanya jika memuat teks asli).
  _Merge _mergeLines(List<_Ln> raw, List<_Ln> bin) {
    final out = <_Ln>[...raw];
    var changed = false;
    for (final b in bin) {
      final bn = norm(b.text);
      if (bn.length < 2) continue;
      int hit = -1;
      for (var i = 0; i < out.length; i++) {
        final r = out[i];
        final ov = math.min(r.box.bottom, b.box.bottom) - math.max(r.box.top, b.box.top);
        final mh = math.min(r.box.height, b.box.height);
        if (mh <= 0 || ov < 0.5 * mh) continue;
        final hov = math.min(r.box.right, b.box.right) - math.max(r.box.left, b.box.left);
        if (hov <= 0) continue;
        hit = i;
        break;
      }
      if (hit < 0) {
        if (letterCount(b.text) >= 3) {
          out.add(b);
          changed = true;
        }
      } else {
        final r = out[hit];
        final rn = norm(r.text);
        final wider = b.box.width >= r.box.width * 1.1;
        if (wider && bn.length > rn.length && (bn.contains(rn) || containedIn(rn, bn))) {
          out[hit] = _Ln(b.text, b.box, 1);
          changed = true;
        }
      }
    }
    return _Merge(out, changed);
  }

  /// Baca satu area pada satu frame -> kandidat (kotak dinormalisasi terhadap seluruh frame).
  Future<List<Cand>> _readArea(OcrArea a, Map<String, dynamic> g, {bool deep = false}) async {
    final path = g['path'] as String;
    final cw = (g['cw'] as num).toInt();
    final ch = (g['ch'] as num).toInt();
    final nx0 = (g['nx0'] as num).toDouble();
    final ny0 = (g['ny0'] as num).toDouble();
    final nx1 = (g['nx1'] as num).toDouble();
    final ny1 = (g['ny1'] as num).toDouble();
    var lines = _cleanLines(await _lines(a, path), a.script);
    var stats = await _stats(a.id, lines);
    var needBin = deep || quality == 2 || lines.fold<int>(0, (s, l) => s + letterCount(l.text)) < 6;
    if (!needBin && quality == 1) {
      // ada teks di sisi kiri/kanan kotak yang tidak terbaca -> kemungkinan terpotong
      for (final s in stats) {
        if ((s['extL'] ?? 0) >= 0.06 || (s['extR'] ?? 0) >= 0.06) {
          needBin = true;
          break;
        }
      }
    }
    if (needBin) {
      try {
        final bi = await _ch.invokeMapMethod<String, dynamic>('binarize', {'id': a.id});
        if (bi != null) {
          final scale = (bi['scale'] as num).toDouble();
          final pad = (bi['pad'] as num).toDouble();
          final bl = _cleanLines(await _lines(a, bi['path'] as String), a.script);
          final mapped = bl
              .map((l) => _Ln(
                  l.text,
                  Rect.fromLTRB((l.box.left - pad) / scale, (l.box.top - pad) / scale, (l.box.right - pad) / scale, (l.box.bottom - pad) / scale),
                  1))
              .toList();
          final mg = _mergeLines(lines, mapped);
          if (mg.changed) {
            lines = mg.lines;
            stats = await _stats(a.id, lines);
          }
        }
      } catch (_) {}
    }
    final out = <Cand>[];
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final st = stats[i];
      final c = Cand(
        l.text,
        nx0 + l.box.left / cw * (nx1 - nx0),
        ny0 + l.box.top / ch * (ny1 - ny0),
        nx0 + l.box.right / cw * (nx1 - nx0),
        ny0 + l.box.bottom / ch * (ny1 - ny0),
        outline: st['outline'] ?? -1.0,
        fill: st['fill'] ?? -1.0,
      );
      if (c.h < 0.012 || c.h > 0.25 || letterCount(c.text) < 2) continue;
      out.add(c);
    }
    return out;
  }

  double _minFrac(OcrArea a) => a.full ? kMinTextFrac * 0.3 : kMinTextFrac;

  Future<List<Map<String, dynamic>>?> _grab(int tMs, List<OcrArea> act, {bool force = false}) async {
    final res = await _ch.invokeMethod<List<dynamic>>('grab', {
      'timeMs': tMs,
      'areas': act
          .map((a) => {'id': a.id, 'x0': a.ex0, 'x1': a.ex1, 'y0': a.ey0, 'y1': a.ey1, 'minFrac': _minFrac(a)})
          .toList(),
      'light': light,
      'bright': bright.round(),
      'changeFrac': kChangeFrac,
      'force': force,
    });
    if (res == null) return null;
    return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  String _markFor(Block b) {
    final tr = Track(0, b);
    tr.add(0.33, b);
    final s = scoreTrack(tr, Ctx(), 0.33);
    final mark = s >= kLikely ? '✔' : (s >= kDoubt ? '?' : '✘');
    return '$mark ${b.text.replaceAll('\n', ' / ')}  (${(s * 100).round()}%)';
  }

  Future<void> testOcr() async {
    if (uri == null) return;
    final act = _active;
    if (act.isEmpty) {
      _snack('Aktifkan minimal satu area.');
      return;
    }
    setState(() => testResult = 'Membaca...');
    try {
      final g = await _grab((previewT * 1000).round(), act, force: true);
      if (g == null) throw Exception('frame tidak terbaca');
      final b = StringBuffer();
      for (final m in g) {
        final a = act.firstWhere((x) => x.id == (m['id'] as num).toInt());
        if (m['ok'] != true || m['path'] == null) continue;
        final cands = await _readArea(a, m);
        final blocks = buildBlocks(cands).where((x) => letterCount(x.text) >= 2).toList();
        b.writeln('${a.name}:');
        if (blocks.isEmpty) {
          final frac = (m['frac'] as num).toDouble();
          b.writeln(frac < _minFrac(a) ? '  (teks terang tidak terdeteksi: cek waktu/area atau turunkan ambang kecerahan)' : '  (kosong)');
        }
        for (final bl in blocks) {
          b.writeln('  ${_markFor(bl)}');
        }
      }
      b.write('✔ subtitle   ? meragukan   ✘ bukan subtitle. Skor tes memakai 1 frame; hasil akhir memakai banyak frame.');
      setState(() => testResult = b.toString());
    } catch (e) {
      setState(() => testResult = 'Error: $e');
    }
  }

  String _sig(int s, int e, int step, List<OcrArea> act) =>
      'v6|$uri|$s|$e|$step|${act.map((a) => a.sig).join(';')}|$light|${bright.round()}|$adaptive|$strictLatin|$quality';

  Future<void> clearTemp() async {
    try {
      final f = File('$filesDir/ocr_raw.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    setState(() {
      steps = [];
      progress = 0;
      status = 'Hasil sementara dihapus.';
    });
  }

  Future<void> runOcr() async {
    if (uri == null || running) return;
    final act = _active;
    if (act.isEmpty) {
      _snack('Aktifkan minimal satu area.');
      return;
    }
    final startMs = testMode ? (previewT * 1000).round() : 0;
    final endMs = testMode ? math.min(durMs, startMs + 60000) : durMs;
    final step = (interval * 1000).round();
    final total = ((endMs - startMs) / step).floor();
    if (total <= 0) {
      _snack('Rentang waktu terlalu pendek.');
      return;
    }
    final sig = _sig(startMs, endMs, step, act);
    final rawFile = File('$filesDir/ocr_raw.json');
    var list = <OcrStep>[];
    try {
      if (await rawFile.exists()) {
        final j = jsonDecode(await rawFile.readAsString()) as Map<String, dynamic>;
        if (j['sig'] == sig) {
          list = (j['steps'] as List).map((e) => OcrStep.fromJson(e as Map<String, dynamic>)).toList();
        }
      }
    } catch (_) {
      list = [];
    }

    Future<void> checkpoint() async {
      try {
        await rawFile.writeAsString(jsonEncode({
          'sig': sig,
          'iv': interval,
          'cov': [startMs / 1000.0, endMs / 1000.0],
          'areas': act.map((a) => a.toJson()).toList(),
          'steps': list.map((s) => s.toJson()).toList(),
        }));
      } catch (_) {}
    }

    final resumedFrom = list.length;
    setState(() {
      running = true;
      cancel = false;
      steps = list;
      progress = list.length / total;
      status = list.isEmpty ? 'Memulai...' : 'Melanjutkan dari ${list.length}/$total';
    });
    _persist();
    try {
      await _ch.invokeMethod('serviceStart', {'text': 'OCR dimulai...'});
    } catch (_) {}
    await _ch.invokeMethod('resetPrev');
    final t0 = DateTime.now();
    final lastCands = <int, List<Cand>>{};
    if (list.isNotEmpty) {
      list.last.c.forEach((k, v) => lastCands[k] = v);
    }
    var failStreak = 0;
    var frameFails = 0;

    Future<Map<int, List<Cand>>> sampleAt(int n) async {
      final tMs = startMs + n * step;
      final res = <int, List<Cand>>{for (final a in act) a.id: <Cand>[]};
      try {
        final g = await _grab(tMs, act);
        if (g == null) {
          frameFails++;
        } else {
          for (final m in g) {
            final id = (m['id'] as num).toInt();
            final a = act.firstWhere((x) => x.id == id);
            if (m['ok'] != true) {
              frameFails++;
              continue;
            }
            final frac = (m['frac'] as num).toDouble();
            final changed = (m['changed'] as num).toDouble();
            final path = m['path'] as String?;
            if (frac < _minFrac(a)) {
              res[id] = <Cand>[];
            } else if (changed >= 0 && changed < kChangeFrac) {
              res[id] = lastCands[id] ?? <Cand>[];
            } else if (path != null) {
              res[id] = await _readArea(a, m);
            }
          }
        }
        failStreak = 0;
      } catch (e) {
        failStreak++;
        if (failStreak >= 20) throw Exception('Terlalu banyak kegagalan beruntun: $e');
      }
      res.forEach((k, v) => lastCands[k] = v);
      return res;
    }

    bool sameText(String a, String b) {
      if (a.isEmpty || b.isEmpty) return a.isEmpty && b.isEmpty;
      final na = norm(a);
      final nb = norm(b);
      return na == nb || similar(na, nb);
    }

    bool sameStep(Map<int, List<Cand>> a, Map<int, List<Cand>> b) {
      for (final ar in act) {
        if (!sameText(_joined(a[ar.id]), _joined(b[ar.id]))) return false;
      }
      return true;
    }

    void push(int n, Map<int, List<Cand>> c) => list.add(OcrStep((startMs + n * step) / 1000.0, c));

    try {
      var sinceSave = 0;
      var iter = 0;
      while (list.length < total) {
        if (cancel) break;
        final n = list.length;
        if (adaptive && n >= 1 && n + 1 < total) {
          // Mode cepat: periksa tiap 2 langkah; sampel tengah hanya diperiksa jika kiri & kanan berbeda
          final a = list[n - 1].c;
          final c = await sampleAt(n + 1);
          final b = sameStep(a, c) ? a : await sampleAt(n);
          push(n, b);
          push(n + 1, c);
          sinceSave += 2;
        } else {
          push(n, await sampleAt(n));
          sinceSave += 1;
        }
        if (sinceSave >= kSaveEvery) {
          await checkpoint();
          sinceSave = 0;
        }
        if (iter++ % 3 == 0) {
          final el = DateTime.now().difference(t0).inSeconds;
          final done = list.length;
          final doneNow = done - resumedFrom;
          final eta = (doneNow > 10 && el > 0) ? fmtDur(((total - done) * el / doneNow).round()) : 'menghitung...';
          setState(() {
            progress = done / total;
            status = 'OCR $done/$total  •  berjalan ${fmtDur(el)}  •  sisa ±$eta';
          });
          try {
            await _ch.invokeMethod('serviceUpdate', {'text': 'OCR $done/$total  •  sisa ±$eta', 'cur': done, 'max': total});
          } catch (_) {}
        }
      }
      await checkpoint();
      covLo = startMs / 1000.0;
      covHi = (startMs + list.length * step) / 1000.0;
      setState(() => status = 'Menganalisis hasil...');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final merged = _analyze(list, interval, act);
      final nonEmpty = list.where((s) => s.c.values.any((v) => v.isNotEmpty)).length;
      final good = merged.where((s) => s.cls == clsLikely).length;
      final doubt = merged.where((s) => s.cls == clsDoubt).length;
      setState(() {
        steps = list;
        subs = merged;
        progress = list.length / total;
        status = cancel
            ? 'Dihentikan di ${list.length}/$total. Tekan Mulai untuk melanjutkan.'
            : 'Selesai: ${list.length} sampel, $nonEmpty berisi teks → $good subtitle, $doubt meragukan.' +
                (frameFails > 0 ? ' ($frameFails frame gagal dibaca)' : '') +
                (nonEmpty == 0 ? ' PERINGATAN: tidak ada teks terbaca. Cek area, jenis tulisan, dan ambang kecerahan.' : '');
      });
      await saveSubs();
      if (!cancel) {
        try {
          await _ch.invokeMethod('notifyDone', {'text': 'Selesai: $good subtitle. Ketuk untuk melihat hasil.'});
        } catch (_) {}
        if (merged.isNotEmpty) _tabs.animateTo(2);
      }
    } catch (e) {
      await checkpoint();
      setState(() => status = 'Berhenti karena error: $e (hasil sementara tersimpan, tekan Mulai untuk melanjutkan)');
    } finally {
      try {
        await _ch.invokeMethod('serviceStop');
      } catch (_) {}
      if (mounted) setState(() => running = false);
    }
  }

  /// Langkah OCR -> pelacakan per area -> skor -> (opsional) pencocokan referensi.
  List<Sub> _analyze(List<OcrStep> list, double iv, List<OcrArea> act) {
    final all = <Sub>[];
    for (final a in act) {
      final samples = list.map((s) => Sample(s.t, (s.c[a.id] ?? <Cand>[]).map((c) => c.copy()).toList())).toList();
      stripOverlays(samples); // watermark yang menempel di ujung baris pada banyak kalimat
      all.addAll(tracksToSubs(buildTracks(samples, iv), iv, area: a.id));
    }
    all.sort((a, b) => a.start.compareTo(b.start));
    _applyRef(all);
    return all;
  }

  /// Analisis ulang dari hasil OCR tersimpan (tanpa OCR lagi), mis. setelah memuat referensi.
  Future<void> reanalyze() async {
    if (running) return;
    try {
      final f = File('$filesDir/ocr_raw.json');
      if (!await f.exists()) {
        _snack('Tidak ada hasil OCR tersimpan. Jalankan OCR dulu.');
        return;
      }
      setState(() => status = 'Menganalisis ulang...');
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final list = (j['steps'] as List).map((e) => OcrStep.fromJson(e as Map<String, dynamic>)).toList();
      final iv = (j['iv'] as num).toDouble();
      final act = (j['areas'] as List).map((e) => OcrArea.fromJson(e as Map<String, dynamic>)).toList();
      final cov = j['cov'] as List;
      covLo = (cov[0] as num).toDouble();
      covHi = (list.isEmpty ? (cov[1] as num).toDouble() : list.last.t + iv);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final merged = _analyze(list, iv, act);
      setState(() {
        subs = merged;
        status = 'Analisis ulang selesai: ${merged.length} entri.';
      });
      await saveSubs();
    } catch (e) {
      _snack('Gagal menganalisis ulang: $e');
    }
  }

  // ===================== hasil =====================
  Future<void> saveSubs() async {
    try {
      await File('$filesDir/subs.json').writeAsString(jsonEncode({
        'name': name,
        'subs': subs.map((s) => s.toJson()).toList(),
        'cov': [covLo, covHi],
        'vw': vw,
        'vh': vh,
        'refOffset': refOffset,
        'refStatus': refStatus,
      }));
    } catch (_) {}
  }

  String _baseName() {
    var base = name.isEmpty ? 'subtitle' : name;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    return base;
  }

  Future<void> exportFile({required bool ass}) async {
    final n = subs.where((s) => s.exportable).length + (includeDoubtful ? subs.where((s) => s.cls == clsDoubt && !s.accepted && s.text.trim().isNotEmpty).length : 0);
    if (n == 0) {
      _snack('Belum ada subtitle yang siap diekspor. Terima dulu yang meragukan di tab Hasil.');
      return;
    }
    final act = _active;
    final jaOnly = act.isNotEmpty && act.every((a) => a.script == 1);
    final fileName = '${_baseName()}${testMode ? '.TEST' : ''}${jaOnly ? '.ja' : ''}${ass ? '.ass' : '.srt'}';
    final text = ass
        ? buildAss(subs, width: vw, height: vh, includeDoubtful: includeDoubtful, fontPx: assPct > 0 ? assPct / 100 * (vh > 0 ? vh : 720) : null)
        : buildSrt(subs, includeDoubtful: includeDoubtful);
    try {
      final where = await _ch.invokeMethod<String>('save', {'name': fileName, 'text': text, 'mime': ass ? 'text/x-ssa' : 'application/x-subrip'});
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(ass ? 'ASS tersimpan' : 'SRT tersimpan'),
          content: Text('$where ($n subtitle)\n\nDi MX Player: menu subtitle → Buka → pilih file ini dari folder Download.'
              '${ass ? '\n\nASS memakai ukuran huruf tetap dan posisi tetap per lajur (atas / tengah / bawah). Jika pemutar mengabaikan ASS, pakai SRT.' : '\n\nSRT tidak menyimpan posisi (atas/bawah). Dua subtitle yang tampil bersamaan menjadi dua entri.'}'
              '${testMode ? '\n\nIni hasil UJI. Matikan "Mode uji" di tab Siapkan untuk memproses seluruh video.' : ''}'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      _snack('Gagal menyimpan: $e');
    }
  }

  Future<void> autoFix() async {
    final fixes = buildFixes(subs.where((s) => s.cls != clsNon).toList());
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
      s.text = s.text.replaceAllMapped(wordRe, (m) {
        final w = m.group(0)!;
        final f = fixes[w.toLowerCase()];
        return f == null ? w : matchCase(w, f);
      });
    }
    setState(() {});
    await saveSubs();
    _snack('Koreksi diterapkan.');
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

  // ===================== review: terima / hapus / baca ulang =====================
  void _accept(Sub s) {
    s.accepted = true;
    s.cls = clsLikely;
    s.warn.removeWhere((w) => w == 'lowconf' || w == 'recovered' || w == 'single' || w == 'noref' || w == 'lowpair');
  }

  Future<void> acceptAllDoubtful() async {
    final list = subs.where((s) => s.cls == clsDoubt && s.text.trim().isNotEmpty).toList();
    if (list.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Terima ${list.length} yang meragukan?'),
        content: const Text('Semuanya akan ikut diekspor. Periksa dulu daftarnya jika tidak yakin.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Terima')),
        ],
      ),
    );
    if (yes != true) return;
    for (final s in list) {
      _accept(s);
    }
    setState(() {});
    await saveSubs();
  }

  Future<void> deleteAllNon() async {
    final n = subs.where((s) => s.cls == clsNon).length;
    if (n == 0) return;
    setState(() => subs.removeWhere((s) => s.cls == clsNon));
    await saveSubs();
    _snack('$n entri bukan-subtitle dihapus.');
  }

  double _vStart(Sub s) => s.cls == clsMissing && refOffset != null && s.refStart != null ? s.refStart! - refOffset! : (s.origStart ?? s.start);
  double _vEnd(Sub s) => s.cls == clsMissing && refOffset != null && s.refEnd != null ? s.refEnd! - refOffset! : (s.origEnd ?? s.end);

  /// Baca ulang beberapa frame di rentang subtitle dengan area seluruh layar + gambar hitam-putih.
  /// Mengembalikan blok teks yang ditemukan di tiap waktu.
  Future<List<List<Block>>> _rereadBlocks(Sub s) async {
    final a0 = areas.firstWhere((a) => a.id == s.area, orElse: () => areas.first);
    final wide = OcrArea(kWideId, full: true, script: a0.script);
    final vs = _vStart(s);
    final ve = math.max(vs + 0.3, _vEnd(s));
    final out = <List<Block>>[];
    for (var k = 1; k <= 5; k++) {
      final t = vs + (ve - vs) * k / 6;
      final g = await _grab((t * 1000).round(), [wide], force: true);
      if (g == null || g.isEmpty || g.first['ok'] != true || g.first['path'] == null) continue;
      final cands = await _readArea(wide, g.first, deep: true);
      out.add(buildBlocks(cands).where((b) => letterCount(b.text) >= 2).toList());
    }
    return out;
  }

  /// Teks usulan hasil baca ulang untuk satu subtitle (null = bukti belum cukup).
  Future<String?> _recoverText(Sub s) async {
    final per = await _rereadBlocks(s);
    final options = <String>[];
    if (s.text.trim().isEmpty) {
      // dialog yang hanya ada di referensi: ambil blok paling mirip kalimat di tiap frame
      for (final blocks in per) {
        Block? best;
        var bs = 0.0;
        for (final b in blocks) {
          final sc = textScore(b.text);
          if (sc > bs) {
            bs = sc;
            best = b;
          }
        }
        if (best != null && bs >= 0.6) options.add(best.text);
      }
      final cnt = <String, int>{};
      final rep = <String, String>{};
      for (final t in options) {
        final n = norm(t);
        cnt[n] = (cnt[n] ?? 0) + 1;
        rep.putIfAbsent(n, () => t);
      }
      String? bestN;
      cnt.forEach((k, v) {
        if (v >= 2 && (bestN == null || v > cnt[bestN]!)) bestN = k;
      });
      return bestN == null ? null : rep[bestN];
    }
    final cn = norm(s.text);
    for (final blocks in per) {
      Block? best;
      for (final b in blocks) {
        final bn = norm(b.text);
        if (bn.contains(cn) || containedIn(cn, bn) || containedIn(bn, cn) || simRatio(bn, cn) >= 0.6) {
          if (best == null || b.text.length > best.text.length) best = b;
        }
      }
      if (best != null) options.add(best.text);
    }
    return pickRecovered(s.text, options);
  }

  Future<void> recoverOne(Sub s) async {
    if (uri == null) {
      _snack('Buka video dulu di tab Siapkan.');
      return;
    }
    if (running) return;
    setState(() => status = 'Membaca ulang frame...');
    try {
      final t = await _recoverText(s);
      setState(() => status = 'Selesai membaca ulang.');
      if (t == null) {
        _snack('Tidak ada versi yang lebih lengkap dan konsisten (bukti kurang). Teks asli dipertahankan.');
        return;
      }
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Hasil baca ulang'),
          content: Text('Sebelumnya:\n${s.text.isEmpty ? '(kosong)' : s.text}\n\nSekarang:\n$t'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abaikan')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Pakai')),
          ],
        ),
      );
      if (yes == true) {
        s.text = t;
        s.alt = null;
        s.warn.removeWhere((w) => w == 'trunc' || w == 'trunc_ref' || w == 'missing');
        if (s.cls == clsMissing) s.cls = clsDoubt;
        s.warn.add('recovered');
        setState(() {});
        await saveSubs();
      }
    } catch (e) {
      setState(() => status = 'Baca ulang gagal: $e');
    }
  }

  /// Baca ulang semua yang bertanda terpotong / tanpa OCR. Hanya mengubah jika ada bukti; hasilnya ditandai untuk dicek.
  Future<void> recoverBatch() async {
    if (uri == null) {
      _snack('Buka video dulu di tab Siapkan.');
      return;
    }
    if (running) return;
    final todo = subs.where((s) => s.cls == clsMissing || s.warn.contains('trunc') || s.warn.contains('trunc_ref')).toList();
    if (todo.isEmpty) {
      _snack('Tidak ada yang perlu dipulihkan.');
      return;
    }
    setState(() {
      running = true;
      cancel = false;
    });
    try {
      await _ch.invokeMethod('serviceStart', {'text': 'Membaca ulang frame...'});
    } catch (_) {}
    var fixed = 0;
    try {
      for (var i = 0; i < todo.length; i++) {
        if (cancel) break;
        setState(() {
          progress = i / todo.length;
          status = 'Membaca ulang ${i + 1}/${todo.length} • berhasil $fixed';
        });
        final s = todo[i];
        final t = await _recoverText(s);
        if (t != null) {
          s.text = t;
          s.alt = null;
          s.warn.removeWhere((w) => w == 'trunc' || w == 'trunc_ref' || w == 'missing');
          if (s.cls == clsMissing) s.cls = clsDoubt;
          s.warn.add('recovered');
          fixed++;
        }
      }
      await saveSubs();
      setState(() => status = 'Baca ulang selesai: $fixed dari ${todo.length} berhasil dipulihkan (cek yang bertanda).');
    } catch (e) {
      setState(() => status = 'Baca ulang berhenti: $e');
    } finally {
      try {
        await _ch.invokeMethod('serviceStop');
      } catch (_) {}
      if (mounted) setState(() => running = false);
    }
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
          title: const Text('Periksa subtitle'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Keyakinan: ${(s.eff * 100).round().clamp(0, 100)}% • ${const ['kemungkinan subtitle', 'meragukan', 'kemungkinan bukan subtitle', 'ada di referensi, tidak terbaca OCR'][s.cls.clamp(0, 3).toInt()]}'
                  '${s.accepted ? ' • diterima' : ''}'),
              if (s.warn.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text('⚠ ${s.warn.map(warnLabel).join('; ')}', style: const TextStyle(color: Colors.orange)),
                ),
              if (s.refText != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('Referensi (${fmtSrt(s.refStart ?? 0)}):\n${s.refText}', style: const TextStyle(fontStyle: FontStyle.italic)),
                ),
              if (s.origStart != null && ((s.origStart! - s.start).abs() > 0.01))
                Text('Waktu OCR asli: ${fmtSrt(s.origStart!)} → ${fmtSrt(s.origEnd ?? s.origStart!)}', style: const TextStyle(fontSize: 12)),
              if (s.alt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: OutlinedButton(
                    onPressed: () => setD(() => ct.text = s.alt!),
                    child: Text('Pakai versi lebih panjang:\n${s.alt}'),
                  ),
                ),
              if (frame != null) Image.memory(frame!),
              TextField(controller: cs, decoration: const InputDecoration(labelText: 'Mulai (00:00:00,000)')),
              TextField(controller: ce, decoration: const InputDecoration(labelText: 'Selesai')),
              TextField(controller: ct, maxLines: 4, decoration: const InputDecoration(labelText: 'Teks Indonesia')),
              if (err != null) Text(err!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 0, children: [
                TextButton(
                  onPressed: () async {
                    if (uri == null) {
                      setD(() => err = 'Buka video dulu di tab Siapkan untuk melihat frame.');
                      return;
                    }
                    try {
                      final t = (_vStart(s) + _vEnd(s)) / 2;
                      final r = await _ch.invokeMapMethod<String, dynamic>('frame', {'timeMs': (t * 1000).round(), 'maxW': 700});
                      setD(() => frame = r?['bytes'] as Uint8List?);
                    } catch (e) {
                      setD(() => err = 'Frame gagal: $e');
                    }
                  },
                  child: const Text('Lihat frame'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(c);
                    await recoverOne(s);
                  },
                  child: const Text('Baca ulang frame'),
                ),
                TextButton(
                  onPressed: () {
                    final i = subs.indexOf(s);
                    if (i >= 0 && i + 1 < subs.length) {
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
                    final ns = Sub(s.end + 0.05, s.end + 2.05, '(ketik teks)', []);
                    ns.accepted = true;
                    ns.area = s.area;
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
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Batal')),
            TextButton(
              onPressed: () {
                _accept(s);
                setState(() {});
                saveSubs();
                Navigator.pop(c);
              },
              child: const Text('Terima'),
            ),
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
                  if (s.text.isNotEmpty) _accept(s);
                  subs.sort((a, b) => a.start.compareTo(b.start));
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

  // ===================== UI =====================
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

  int _freeId() {
    for (var i = 0; i < 6; i++) {
      if (!areas.any((a) => a.id == i)) return i;
    }
    return 5;
  }

  Widget _areaTile(OcrArea a) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        title: Text('${a.name} • ${a.scriptName}'),
        subtitle: Text(a.full ? 'seluruh layar' : 'kotak ${_pct(a.y0)}–${_pct(a.y1)} (atas–bawah)'),
        trailing: Switch(value: a.enabled, onChanged: running ? null : (v) => _set(() => a.enabled = v)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Seluruh layar (posisi berpindah-pindah)'),
            subtitle: const Text('Atas / tengah / bawah dibaca semua. Tulisan non-subtitle disaring otomatis.'),
            value: a.full,
            onChanged: (v) => _set(() => a.full = v),
          ),
          if (!a.full) ...[
            Text('Atas – Bawah: ${_pct(a.y0)} – ${_pct(a.y1)}'),
            RangeSlider(
                values: RangeValues(a.y0, a.y1), min: 0, max: 1, onChanged: (v) => setState(() { a.y0 = v.start; a.y1 = v.end; }), onChangeEnd: (_) => _persist()),
            Text('Kiri – Kanan: ${_pct(a.x0)} – ${_pct(a.x1)}'),
            RangeSlider(
                values: RangeValues(a.x0, a.x1), min: 0, max: 1, onChanged: (v) => setState(() { a.x0 = v.start; a.x1 = v.end; }), onChangeEnd: (_) => _persist()),
            const Text('Kotak berwarna harus menutupi subtitle. Beri sedikit ruang kiri-kanan agar kalimat panjang tidak terpotong.', style: TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 4),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Latin')),
              ButtonSegment(value: 1, label: Text('Jepang')),
              ButtonSegment(value: 2, label: Text('Keduanya')),
            ],
            selected: {a.script},
            onSelectionChanged: (s) => _set(() => a.script = s.first),
          ),
          if (areas.length > 1)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: running ? null : () => _set(() => areas.remove(a)),
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('Hapus area ini', style: TextStyle(color: Colors.red)),
              ),
            ),
        ],
      ),
    );
  }

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
                CustomPaint(painter: _AreaPainter(_active)),
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
      ],
      _card('3. Area OCR', [
        for (final a in areas) _areaTile(a),
        if (areas.length < kMaxAreas)
          OutlinedButton.icon(
            onPressed: running ? null : () => _set(() => areas.add(OcrArea(_freeId(), full: false, y0: 0.0, y1: 0.25, script: 0))),
            icon: const Icon(Icons.add),
            label: const Text('Tambah area (mis. teks Jepang di bawah)'),
          ),
        if (areas.any((a) => a.script == 0))
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Buang area tulisan Jepang di area Latin'),
            subtitle: const Text('Mencegah huruf Jepang terbaca sebagai huruf Latin aneh. Sedikit lebih lambat.'),
            value: strictLatin,
            onChanged: (v) => _set(() => strictLatin = v),
          ),
      ], hint: 'Setiap area punya hasil dan riwayat teks sendiri. Tulisan pada benda/logo disaring dengan skor, bukan dengan mempersempit area.'),
      _card('4. Subtitle referensi Inggris (opsional)', [
        OutlinedButton.icon(
          onPressed: running ? null : pickRef,
          icon: const Icon(Icons.upload_file),
          label: Text(refCues.isEmpty ? 'Pilih file .srt atau .ass Inggris' : 'Ganti file referensi'),
        ),
        if (refCues.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('$refName\n${refCues.length} dialog • ${fmtClock(refCues.first.start)} – ${fmtClock(refCues.last.end)}'),
          ),
        const SizedBox(height: 8),
        const Text('Garis waktu hasil:'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Ikuti referensi')),
            ButtonSegment(value: 1, label: Text('Ikuti video')),
          ],
          selected: {refTimeline},
          onSelectionChanged: (s) => _set(() => refTimeline = s.first),
        ),
        const SizedBox(height: 4),
        const Text(
          'Ikuti referensi: untuk dipakai pada video/rilis yang waktunya sama dengan SRT Inggris. Ikuti video: untuk dipakai pada video hardsub ini.\n'
          'Waktu hanya dikoreksi untuk pasangan yang yakin, dan hanya jika kedua sumber tampak versi video yang sama. Teks Indonesia tidak pernah diterjemahkan atau diganti.',
          style: TextStyle(fontSize: 12),
        ),
        if (refCues.isNotEmpty)
          Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: running ? null : clearRef, child: const Text('Hapus referensi'))),
      ]),
      if (uri != null)
        _card('5. Tes', [
          OutlinedButton.icon(onPressed: running ? null : testOcr, icon: const Icon(Icons.science), label: const Text('Tes OCR pada waktu ini')),
          if (testResult.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(testResult, style: const TextStyle(fontSize: 15))),
        ], hint: 'Hasil harus sama dengan subtitle di video; tulisan pada benda harus bertanda ✘. Coba beberapa waktu berbeda.'),
      Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ExpansionTile(
          title: const Text('Pengaturan lanjutan'),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Teks subtitle terang (putih/kuning)'),
              subtitle: const Text('Matikan jika teksnya gelap'),
              value: light,
              onChanged: (v) => _set(() => light = v),
            ),
            Text('Ambang kecerahan teks: ${bright.round()}  (turunkan jika teks redup, naikkan jika latar terang)'),
            Slider(value: bright, min: 120, max: 245, onChanged: (v) => setState(() => bright = v), onChangeEnd: (_) => _persist()),
            const Text('Ketelitian baca'),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Cepat')),
                ButtonSegment(value: 1, label: Text('Seimbang')),
                ButtonSegment(value: 2, label: Text('Teliti')),
              ],
              selected: {quality},
              onSelectionChanged: (s) => _set(() => quality = s.first),
            ),
            const Text(
              'Cepat: baca sekali. Seimbang: baca ulang (hitam-putih) hanya jika ada teks terpotong di sisi kalimat. Teliti: selalu baca 2x (paling lambat).',
              style: TextStyle(fontSize: 12),
            ),
            Row(children: [
              const Text('Interval: '),
              DropdownButton<double>(
                value: interval,
                items: const [
                  DropdownMenuItem(value: 0.33, child: Text('0,33 dtk (teliti)')),
                  DropdownMenuItem(value: 0.5, child: Text('0,5 dtk (seimbang)')),
                  DropdownMenuItem(value: 1.0, child: Text('1 dtk (cepat, kasar)')),
                ],
                onChanged: (v) => _set(() => interval = v ?? 0.33),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mode cepat adaptif'),
              subtitle: const Text('Periksa tiap 2 langkah, rapatkan hanya di dekat pergantian teks (±1,5–2x lebih cepat). Subtitle < 0,7 dtk bisa terlewat.'),
              value: adaptive,
              onChanged: (v) => _set(() => adaptive = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mode uji (60 detik dari waktu di atas)'),
              subtitle: const Text('Matikan untuk memproses seluruh video.'),
              value: testMode,
              onChanged: (v) => _set(() => testMode = v),
            ),
          ],
        ),
      ),
      FilledButton.icon(onPressed: () => _tabs.animateTo(1), icon: const Icon(Icons.arrow_forward), label: const Text('Lanjut ke Proses')),
      const SizedBox(height: 24),
    ]);
  }

  Widget _tabProses() {
    final act = _active;
    return ListView(padding: const EdgeInsets.all(12), children: [
      _card('Ringkasan', [
        Text(uri == null
            ? 'Pilih video dulu di tab Siapkan.'
            : '$name\n'
                'Mode: ${testMode ? 'UJI 60 detik' : 'PENUH'}\n'
                '${act.map((a) => '${a.name}: ${a.scriptName}, ${a.full ? 'seluruh layar' : 'kotak ${_pct(a.y0)}–${_pct(a.y1)}'}').join('\n')}\n'
                'Interval: $interval dtk${adaptive ? ' (cepat adaptif)' : ''} • ketelitian: ${const ['cepat', 'seimbang', 'teliti'][quality]}\n'
                'Referensi: ${refCues.isEmpty ? 'tidak dipakai' : '$refName (${refCues.length} dialog)'}'),
      ]),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: (uri == null || running) ? null : runOcr,
            icon: const Icon(Icons.play_arrow),
            label: Text(steps.isNotEmpty && !running ? 'Mulai / Lanjutkan' : 'Mulai'),
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
      Wrap(spacing: 8, children: [
        if (!running && steps.isNotEmpty) TextButton(onPressed: clearTemp, child: const Text('Hapus hasil sementara (mulai dari awal)')),
        if (!running) TextButton(onPressed: reanalyze, child: const Text('Analisis ulang dari hasil OCR tersimpan')),
      ]),
      const SizedBox(height: 8),
      _card('Catatan', [
        const Text(
          '• Boleh ditinggal: tekan Home atau kunci layar, proses tetap jalan (ada notifikasi progres).\n'
          '• Jangan geser/tutup app dari daftar aplikasi terbaru. Jika terlanjur, buka lagi lalu tekan Mulai: proses melanjutkan dari hasil tersimpan.\n'
          '• Waktu subtitle adalah perkiraan dari frame yang diperiksa, bukan timestamp asli. Akurasi OCR tidak 100%: periksa hasilnya di tab Hasil.\n'
          '• Entri yang meragukan TIDAK ikut diekspor sampai Anda menerimanya.',
        ),
      ]),
    ]);
  }

  static const List<String> _filterNames = [
    'Semua',
    'Perlu cek',
    'Meragukan',
    'Tanpa pasangan',
    'Terpotong',
    'Bentrok',
    'Geser besar',
    'Tanpa OCR',
    'Bukan subtitle',
  ];

  bool _pass(Sub s, int f) {
    switch (f) {
      case 0:
        return s.cls != clsNon;
      case 1:
        return s.cls != clsNon && !s.accepted && (s.warn.isNotEmpty || s.cls != clsLikely);
      case 2:
        return s.cls == clsDoubt && !s.accepted;
      case 3:
        return s.warn.contains('noref');
      case 4:
        return s.warn.contains('trunc') || s.warn.contains('trunc_ref') || s.alt != null;
      case 5:
        return s.warn.contains('conflict');
      case 6:
        return s.warn.contains('bigshift');
      case 7:
        return s.cls == clsMissing;
      case 8:
        return s.cls == clsNon;
    }
    return true;
  }

  Widget _tabHasil() {
    final shown = <Sub>[for (final s in subs) if (_pass(s, filter)) s];
    final ready = subs.where((s) => s.exportable).length;
    final doubt = subs.where((s) => s.cls == clsDoubt && !s.accepted).length;
    final missing = subs.where((s) => s.cls == clsMissing).length;
    final non = subs.where((s) => s.cls == clsNon).length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('$ready siap ekspor • $doubt meragukan • $missing tanpa OCR • $non disaring (bukan subtitle)'),
        ),
      ),
      if (refStatus.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Align(alignment: Alignment.centerLeft, child: Text(refStatus, style: Theme.of(context).textTheme.bodySmall)),
        ),
      SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (var i = 0; i < _filterNames.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: FilterChip(
                label: Text('${_filterNames[i]} (${subs.where((s) => _pass(s, i)).length})'),
                selected: filter == i,
                onSelected: (_) => setState(() => filter = i),
              ),
            ),
        ]),
      ),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (final e in <MapEntry<String, VoidCallback?>>[
            MapEntry('Terima semua meragukan', doubt == 0 ? null : acceptAllDoubtful),
            MapEntry('Sinkron referensi', refCues.isEmpty || subs.isEmpty ? null : _syncNow),
            MapEntry('Baca ulang terpotong/hilang', (running || uri == null) ? null : recoverBatch),
            MapEntry('Perbaiki otomatis', subs.isEmpty ? null : autoFix),
            MapEntry('Cari & ganti', subs.isEmpty ? null : findReplace),
            MapEntry('Hapus bukan-subtitle', non == 0 ? null : deleteAllNon),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: ActionChip(label: Text(e.key), onPressed: e.value),
            ),
        ]),
      ),
      Expanded(
        child: shown.isEmpty
            ? const Center(child: Text('Tidak ada entri di filter ini.'))
            : ListView.builder(
                itemCount: shown.length,
                itemBuilder: (c, k) {
                  final s = shown[k];
                  final icon = s.accepted
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : s.cls == clsLikely
                          ? const Icon(Icons.check_circle_outline, color: Colors.green)
                          : s.cls == clsDoubt
                              ? const Icon(Icons.help_outline, color: Colors.orange)
                              : s.cls == clsMissing
                                  ? const Icon(Icons.report_gmailerrorred, color: Colors.red)
                                  : const Icon(Icons.block, color: Colors.grey);
                  final ref = s.refText == null ? '' : '\nEN: ${s.refText!.replaceAll('\n', ' / ')}';
                  return ListTile(
                    dense: true,
                    leading: icon,
                    title: Text(s.text.isEmpty ? '(tidak terbaca)' : s.text.replaceAll('\n', ' / ')),
                    subtitle: Text(
                      '${fmtSrt(s.start)} → ${fmtSrt(s.end)} • ${areas.where((a) => a.id == s.area).isEmpty ? 'Area ${s.area + 1}' : areas.firstWhere((a) => a.id == s.area).name}'
                      '${s.warn.isEmpty ? '' : '\n⚠ ${s.warn.map(warnLabel).join('; ')}'}$ref',
                      style: TextStyle(color: s.warn.isEmpty || s.accepted ? null : Colors.orange),
                    ),
                    onTap: () => editSub(s),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('Sertakan yang meragukan ($doubt)'),
          value: includeDoubtful,
          onChanged: (v) => setState(() => includeDoubtful = v),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Row(children: [
          const Text('Ukuran huruf ASS: '),
          DropdownButton<double>(
            value: const [0.0, 4.0, 4.5, 5.0, 5.5, 6.0, 7.0].contains(assPct) ? assPct : 0.0,
            items: const [
              DropdownMenuItem(value: 0.0, child: Text('Otomatis')),
              DropdownMenuItem(value: 4.0, child: Text('Kecil (4%)')),
              DropdownMenuItem(value: 4.5, child: Text('4,5%')),
              DropdownMenuItem(value: 5.0, child: Text('Sedang (5%)')),
              DropdownMenuItem(value: 5.5, child: Text('5,5%')),
              DropdownMenuItem(value: 6.0, child: Text('Besar (6%)')),
              DropdownMenuItem(value: 7.0, child: Text('Sangat besar (7%)')),
            ],
            onChanged: (v) => _set(() => assPct = v ?? 0.0),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Row(children: [
          Expanded(child: FilledButton.icon(onPressed: () => exportFile(ass: false), icon: const Icon(Icons.download), label: const Text('Ekspor SRT'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: () => exportFile(ass: true), icon: const Icon(Icons.download), label: const Text('Ekspor ASS'))),
        ]),
      ),
    ]);
  }
}

class _AreaPainter extends CustomPainter {
  final List<OcrArea> areas;
  _AreaPainter(this.areas);
  static const List<Color> _colors = [Colors.red, Colors.lightBlueAccent, Colors.amber, Colors.greenAccent, Colors.purpleAccent, Colors.orange];
  @override
  void paint(Canvas canvas, Size size) {
    for (final a in areas) {
      final col = _colors[a.id % _colors.length];
      final r = Rect.fromLTRB(a.ex0 * size.width, a.ey0 * size.height, a.ex1 * size.width, a.ey1 * size.height).deflate(1);
      canvas.drawRect(
          r,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      final tp = TextPainter(
        text: TextSpan(text: a.name, style: TextStyle(color: col, fontSize: 11, backgroundColor: Colors.black54)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, r.topLeft + const Offset(3, 3));
    }
  }

  @override
  bool shouldRepaint(covariant _AreaPainter old) => true;
}
