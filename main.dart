import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

// ======================= PENGATURAN OCR =======================
const double kChangeFrac = 0.0015; // frame dianggap sama jika perubahan piksel di bawah ini
const double kMinTextFrac = 0.001; // minimal piksel teks agar dianggap ada subtitle
const double kSim = 0.85; // kemiripan teks agar digabung
const double kMaxDropoutSec = 0.6;
const double kMinDuration = 0.7;
const int kSaveEvery = 100;

const MethodChannel _ch = MethodChannel('hardsub/native');

// ======================= UTILITAS =======================
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

int letterCount(String t) => RegExp(r'[A-Za-zÀ-ɏ]').allMatches(t).length;

String norm(String t) => t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

final RegExp _cjk = RegExp(r'[　-ヿ㐀-䶿一-鿿豈-﫿＀-￯가-힯]');

/// Bersihkan hasil OCR: buang huruf non-Latin & baris sampah.
String cleanText(String t) {
  final out = <String>[];
  for (var line in t.split('\n')) {
    final nCjk = _cjk.allMatches(line).length;
    if (nCjk > 0) {
      final latin = RegExp(r'[A-Za-z]').allMatches(line).length;
      if (latin >= 3 * nCjk && latin >= 3) {
        line = line.replaceAll(_cjk, ' ');
      } else {
        continue;
      }
    }
    line = line.replaceAll(RegExp(r'\s+'), ' ').trim();
    final compact = line.replaceAll(' ', '');
    if (compact.isEmpty) continue;
    final alnum = RegExp(r'[A-Za-z0-9À-ɏ]').allMatches(compact).length;
    if (alnum >= 1 && alnum / compact.length >= 0.6) out.add(line);
  }
  return out.join('\n');
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
  if (math.min(a.length, b.length) < 6) return false; // teks pendek harus identik
  return simRatio(a, b) >= kSim;
}

// ======================= MODEL =======================
class Sample {
  double t;
  String text;
  Sample(this.t, this.text);
  Map<String, dynamic> toJson() => {'t': t, 'text': text};
  factory Sample.fromJson(Map<String, dynamic> j) => Sample((j['t'] as num).toDouble(), j['text'] as String);
}

class Sub {
  double start;
  double end;
  String text;
  List<String> warn;
  Sub(this.start, this.end, this.text, this.warn);
  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'text': text, 'warn': warn};
  factory Sub.fromJson(Map<String, dynamic> j) => Sub((j['start'] as num).toDouble(), (j['end'] as num).toDouble(),
      j['text'] as String, (j['warn'] as List).map((e) => e.toString()).toList());
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

/// Gabungkan sampel OCR menjadi subtitle (port dari versi Colab).
List<Sub> mergeSamples(List<Sample> samples, double interval) {
  const eps = 1e-6;
  final groups = <_G>[];
  _G? cur;
  for (final s in samples) {
    final n = letterCount(s.text) >= 2 ? norm(s.text) : '';
    if (n.isEmpty) continue;
    final c = cur;
    if (c != null) {
      final gap = s.t - c.last;
      final gapOk = gap <= interval + eps || (gap <= interval + kMaxDropoutSec + eps && n.length >= 6);
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

  // Sampel tunggal yang mirip tetangga = salah baca sesaat -> gabungkan ke tetangga
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
    if (r.count == 1 && (letters < 3 || ratio < 0.7)) continue; // hampir pasti sampah
    final warn = <String>[];
    if (r.count == 1) warn.add('hanya terbaca 1 kali');
    if (letters < 4) warn.add('teks sangat pendek');
    if (ratio < 0.7) warn.add('banyak karakter aneh');
    subs.add(Sub(math.max(0.0, r.first - interval / 2), r.last + interval / 2, r.text, warn));
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

String buildSrt(List<Sub> subs) {
  final sorted = [...subs]..sort((a, b) => a.start.compareTo(b.start));
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

// ======================= APLIKASI =======================
void main() => runApp(const HardsubApp());

class HardsubApp extends StatelessWidget {
  const HardsubApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hardsub OCR',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
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

  // video
  String? uri;
  String name = '';
  int durMs = 0;
  int vw = 0, vh = 0;
  double previewT = 0;
  Uint8List? previewBytes;
  double previewAspect = 16 / 9;

  // area & pengaturan
  RangeValues yR = const RangeValues(0.74, 0.97);
  RangeValues xR = const RangeValues(0.05, 0.95);
  double interval = 0.5;
  bool testMode = true;
  bool light = true;
  double bright = 200;
  String testResult = '';

  // proses
  bool running = false;
  bool cancel = false;
  double progress = 0;
  String status = 'Belum mulai.';
  List<Sample> samples = [];

  // hasil
  List<Sub> subs = [];
  bool onlyWarn = false;
  String filesDir = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      filesDir = await _ch.invokeMethod<String>('dirs') ?? '';
      final f = File('$filesDir/subs.json');
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        subs = (j['subs'] as List).map((e) => Sub.fromJson(e as Map<String, dynamic>)).toList();
        name = (j['name'] as String?) ?? '';
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _rec.close();
    _tabs.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ---------- video ----------
  Future<void> pickVideo() async {
    try {
      final u = await _ch.invokeMethod<String>('pick');
      if (u == null) return;
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
        samples = [];
        status = 'Video siap.';
      });
      await loadPreview();
    } catch (e) {
      _snack('Gagal: $e');
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

  // ---------- OCR ----------
  Future<String> _ocrFile(String path) async {
    final r = await _rec.processImage(InputImage.fromFilePath(path));
    final lines = <String>[];
    for (final b in r.blocks) {
      for (final l in b.lines) {
        lines.add(l.text);
      }
    }
    return cleanText(lines.join('\n'));
  }

  Future<String> _ocrBest(String rawPath) async {
    var best = await _ocrFile(rawPath);
    final lt = letterCount(best);
    if (lt >= 6) return best;
    // coba versi hitam-putih (hanya piksel teks)
    final binPath = await _ch.invokeMethod<String>('binarize');
    if (binPath != null) {
      final alt = await _ocrFile(binPath);
      if (letterCount(alt) > lt) best = alt;
    }
    return best;
  }

  Map<String, dynamic> _grabArgs(int tMs, {bool force = false}) => {
        'timeMs': tMs,
        'x0': xR.start,
        'x1': xR.end,
        'y0': yR.start,
        'y1': yR.end,
        'light': light,
        'bright': bright.round(),
        'minFrac': kMinTextFrac,
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
      var txt = path == null ? '' : await _ocrBest(path);
      setState(() => testResult = (frac < kMinTextFrac ? '(Tidak ada teks terang di area ini. Cek waktu/area/ambang.)\n' : '') +
          (txt.isEmpty ? '(kosong)' : txt));
    } catch (e) {
      setState(() => testResult = 'Error: $e');
    }
  }

  String _sig(int s, int e, int step) =>
      '$uri|$s|$e|$step|${xR.start.toStringAsFixed(2)},${xR.end.toStringAsFixed(2)},${yR.start.toStringAsFixed(2)},${yR.end.toStringAsFixed(2)}|$light|${bright.round()}';

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

    setState(() {
      running = true;
      cancel = false;
      samples = list;
      status = list.isEmpty ? 'Memulai...' : 'Melanjutkan dari ${list.length}/$total';
    });
    await _ch.invokeMethod('keepAwake', {'on': true});
    await _ch.invokeMethod('resetPrev');
    final t0 = DateTime.now();
    var prevText = list.isEmpty ? '' : list.last.text;
    var failStreak = 0;
    var frameFails = 0;
    try {
      for (var i = list.length; i < total; i++) {
        if (cancel) break;
        final tMs = startMs + i * step;
        var text = '';
        try {
          final g = await _ch.invokeMapMethod<String, dynamic>('grab', _grabArgs(tMs));
          if (g == null || g['ok'] != true) {
            frameFails++;
            text = '';
          } else {
            final frac = (g['frac'] as num).toDouble();
            final changed = (g['changed'] as num).toDouble();
            final path = g['path'] as String?;
            if (frac < kMinTextFrac) {
              text = '';
            } else if (changed >= 0 && changed < kChangeFrac) {
              text = prevText;
            } else if (path != null) {
              text = await _ocrBest(path);
            }
          }
          failStreak = 0;
        } catch (e) {
          failStreak++;
          if (failStreak >= 20) throw Exception('Terlalu banyak kegagalan beruntun: $e');
        }
        prevText = text;
        list.add(Sample(tMs / 1000.0, text));
        if (list.length % kSaveEvery == 0) await checkpoint();
        if (list.length % 5 == 0 || i == total - 1) {
          final el = DateTime.now().difference(t0).inSeconds;
          final done = list.length;
          setState(() {
            progress = done / total;
            status = 'OCR $done/$total  •  ${el}s berlalu';
          });
        }
      }
      await checkpoint();
      final nonEmpty = list.where((s) => s.text.isNotEmpty).length;
      final merged = mergeSamples(list, interval);
      setState(() {
        samples = list;
        subs = merged;
        status = cancel
            ? 'Dihentikan. Tekan Mulai lagi untuk melanjutkan.'
            : 'Selesai: ${list.length} sampel, $nonEmpty berisi teks, ${merged.length} subtitle.' +
                (frameFails > 0 ? ' ($frameFails frame gagal dibaca)' : '') +
                (nonEmpty == 0 ? ' PERINGATAN: tidak ada teks terbaca — cek area/ambang.' : '');
      });
      await saveSubs();
      if (!cancel && merged.isNotEmpty) _tabs.animateTo(2);
    } catch (e) {
      await checkpoint();
      setState(() => status = 'Berhenti karena error: $e (hasil sementara tersimpan)');
    } finally {
      await _ch.invokeMethod('keepAwake', {'on': false});
      if (mounted) setState(() => running = false);
    }
  }

  // ---------- hasil ----------
  Future<void> saveSubs() async {
    try {
      await File('$filesDir/subs.json').writeAsString(jsonEncode({'name': name, 'subs': subs.map((s) => s.toJson()).toList()}));
    } catch (_) {}
  }

  Future<void> exportSrt() async {
    if (subs.isEmpty) {
      _snack('Belum ada subtitle.');
      return;
    }
    var base = name.isEmpty ? 'subtitle' : name;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    final fileName = '$base${testMode ? '.TEST' : ''}.srt';
    try {
      final where = await _ch.invokeMethod<String>('save', {'name': fileName, 'text': buildSrt(subs)});
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('SRT tersimpan'),
          content: Text('$where\n\nDi MX Player: menu subtitle → Buka → pilih file ini dari folder Download.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      _snack('Gagal menyimpan: $e');
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
                  setD(() => err = 'Buka video dulu di tab 1 untuk melihat frame.');
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

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hardsub OCR → SRT'),
        bottom: TabBar(controller: _tabs, tabs: const [Tab(text: '1 Video'), Tab(text: '2 Proses'), Tab(text: '3 Hasil')]),
      ),
      body: TabBarView(
        controller: _tabs,
        physics: const NeverScrollableScrollPhysics(),
        children: [_tabVideo(), _tabProses(), _tabHasil()],
      ),
    );
  }

  Widget _tabVideo() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      FilledButton.icon(onPressed: running ? null : pickVideo, icon: const Icon(Icons.video_file), label: const Text('Pilih video (MP4/MKV)')),
      if (uri != null) ...[
        const SizedBox(height: 8),
        Text('$name\n${vw}x$vh  •  ${durMs ~/ 60000} menit ${(durMs ~/ 1000) % 60} dtk'),
        const SizedBox(height: 8),
        if (previewBytes != null)
          AspectRatio(
            aspectRatio: previewAspect,
            child: Stack(fit: StackFit.expand, children: [
              Image.memory(previewBytes!, fit: BoxFit.fill, gaplessPlayback: true),
              CustomPaint(painter: _CropPainter(xR, yR)),
            ]),
          ),
        const Text('Geser waktu ke momen yang ADA subtitle-nya:'),
        Slider(
          value: previewT.clamp(0.0, math.max(1.0, durMs / 1000.0 - 1)).toDouble(),
          min: 0,
          max: math.max(1.0, durMs / 1000.0 - 1),
          label: fmtSrt(previewT).substring(0, 8),
          onChanged: (v) => setState(() => previewT = v),
          onChangeEnd: (_) => loadPreview(),
        ),
        const Text('Atas – Bawah (kotak merah harus menutupi subtitle saja):'),
        RangeSlider(values: yR, min: 0, max: 1, onChanged: (v) => setState(() => yR = v)),
        const Text('Kiri – Kanan:'),
        RangeSlider(values: xR, min: 0, max: 1, onChanged: (v) => setState(() => xR = v)),
        const Divider(),
        SwitchListTile(
          title: const Text('Teks subtitle terang (putih/kuning)'),
          subtitle: const Text('Matikan jika teksnya gelap'),
          value: light,
          onChanged: (v) => setState(() => light = v),
        ),
        Text('Ambang kecerahan teks: ${bright.round()} (turunkan jika teks redup/kekuningan)'),
        Slider(value: bright, min: 120, max: 245, onChanged: (v) => setState(() => bright = v)),
        Row(children: [
          const Text('Interval: '),
          DropdownButton<double>(
            value: interval,
            items: const [
              DropdownMenuItem(value: 0.33, child: Text('0,33 dtk (teliti, lambat)')),
              DropdownMenuItem(value: 0.5, child: Text('0,5 dtk (disarankan)')),
              DropdownMenuItem(value: 1.0, child: Text('1 dtk (cepat, kasar)')),
            ],
            onChanged: (v) => setState(() => interval = v ?? 0.5),
          ),
        ]),
        SwitchListTile(
          title: const Text('Mode uji (hanya 60 detik dari waktu di atas)'),
          value: testMode,
          onChanged: (v) => setState(() => testMode = v),
        ),
        OutlinedButton.icon(onPressed: testOcr, icon: const Icon(Icons.science), label: const Text('Tes OCR pada frame ini')),
        if (testResult.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(testResult, style: const TextStyle(fontSize: 16))),
        FilledButton(onPressed: () => _tabs.animateTo(1), child: const Text('Lanjut ke Proses →')),
      ],
    ]);
  }

  Widget _tabProses() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      Text(uri == null ? 'Pilih video dulu di tab 1.' : '$name\nMode: ${testMode ? 'UJI 60 detik' : 'PENUH'}  •  interval $interval dtk'),
      const SizedBox(height: 12),
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
      const SizedBox(height: 16),
      const Text(
        'Biarkan aplikasi tetap terbuka dan layar menyala selama proses (layar otomatis ditahan menyala). '
        'Jika terhenti, tekan Mulai lagi: proses melanjutkan dari hasil tersimpan. '
        'Waktu subtitle adalah perkiraan dari frame yang diperiksa, bukan timestamp asli, dan akurasi OCR tidak 100%.',
        style: TextStyle(color: Colors.grey),
      ),
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
        child: Row(children: [
          Expanded(child: Text('${subs.length} subtitle • $nw ⚠')),
          const Text('Hanya ⚠'),
          Switch(value: onlyWarn, onChanged: (v) => setState(() => onlyWarn = v)),
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
                    subtitle: Text('${i + 1}.  ${fmtSrt(s.start)} → ${fmtSrt(s.end)}${s.warn.isEmpty ? '' : '\n⚠ ${s.warn.join(', ')}'}',
                        style: TextStyle(color: s.warn.isEmpty ? null : Colors.orange)),
                    onTap: () => editSub(s),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(onPressed: exportSrt, icon: const Icon(Icons.download), label: const Text('Ekspor SRT ke folder Download')),
        ),
      ),
    ]);
  }
}

class _CropPainter extends CustomPainter {
  final RangeValues x;
  final RangeValues y;
  _CropPainter(this.x, this.y);
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(x.start * size.width, y.start * size.height, x.end * size.width, y.end * size.height);
    canvas.drawRect(
        r,
        Paint()
          ..color = Colors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.x != x || old.y != y;
}
