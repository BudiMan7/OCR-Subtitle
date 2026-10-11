import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

// =====================================================================
//  HARDSUB OCR → SRT & ASS (Multi-Region & Reference Matched)
// =====================================================================

const double kChangeFrac = 0.0015;
const double kMinTextFrac = 0.001;
const double kSim = 0.85;
const double kMaxDropoutSec = 0.6;
const double kMinDuration = 0.7;
const int kSaveEvery = 100;

const MethodChannel _ch = MethodChannel('hardsub/native');

// ----------------------- model region & referensi -----------------------
class OcrRegion {
  String id;
  String name;
  RangeValues yR;
  RangeValues xR;
  bool active;
  List<Sample> samples = [];
  List<Sub> subs = [];

  OcrRegion({
    required this.id,
    required this.name,
    required this.yR,
    required this.xR,
    this.active = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'y0': yR.start,
        'y1': yR.end,
        'x0': xR.start,
        'x1': xR.end,
        'active': active,
      };

  factory OcrRegion.fromJson(Map<String, dynamic> j) => OcrRegion(
        id: j['id'] as String,
        name: j['name'] as String,
        yR: RangeValues(_d(j['y0'], 0.75), _d(j['y1'], 0.95)),
        xR: RangeValues(_d(j['x0'], 0.05), _d(j['x1'], 0.95)),
        active: j['active'] as bool? ?? true,
      );

  static double _d(dynamic v, double def) => v is num ? v.toDouble() : def;
}

class RefSub {
  double start;
  double end;
  String text;
  RefSub(this.start, this.end, this.text);
}

// ----------------------- util waktu & teks -----------------------
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
  if (m == null) throw const FormatException('Format waktu salah.');
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

// ----------------------- model sample & sub -----------------------
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

class _Ln {
  final String text;
  final Rect box;
  _Ln(this.text, this.box);
}

// ----------------------- pemrosesan lanjutan (Smart Filtering & Match) -----------------------
double evaluateCandidate(String text, int letterCountVal) {
  double score = 1.0;
  if (letterCountVal < 2) score -= 0.5;
  if (text.length > 120) score -= 0.2;
  if (RegExp(r'^[A-Z0-9]{1,4}$').hasMatch(text)) score -= 0.4; // Filter kode acak / logo pendek
  return score.clamp(0.0, 1.0);
}

List<RefSub> parseRefSrt(String content) {
  final result = <RefSub>[];
  final blocks = content.replaceAll('\r\n', '\n').split('\n\n');
  for (final b in blocks) {
    final lines = b.split('\n');
    if (lines.length >= 3) {
      final timeParts = lines[1].split('-->');
      if (timeParts.length == 2) {
        try {
          final s = parseSrt(timeParts[0]);
          final e = parseSrt(timeParts[1]);
          final txt = lines.sublist(2).join('\n');
          result.add(RefSub(s, e, txt));
        } catch (_) {}
      }
    }
  }
  return result;
}

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

  final subs = <Sub>[];
  for (var i = 0; i < recs.length; i++) {
    final r = recs[i];
    final letters = letterCount(r.text);
    final conf = evaluateCandidate(r.text, letters);
    final warn = <String>[];
    if (r.count == 1) warn.add('hanya terbaca 1 kali');
    if (conf < 0.6) warn.add('kandidat meragukan (kemungkinan non-subtitle)');
    
    subs.add(Sub(math.max(0.0, r.first - interval / 2), r.last + interval / 2, r.text, warn));
  }
  for (final s in subs) {
    if (s.end - s.start < kMinDuration) {
      s.end = s.start + kMinDuration;
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

String buildAss(List<OcrRegion> regions) {
  final buffer = StringBuffer();
  buffer.writeln('[Script Info]');
  buffer.writeln('Title: Hardsub OCR Multi-Region Export');
  buffer.writeln('ScriptType: v4.00+');
  buffer.writeln('WrapStyle: 0');
  buffer.writeln('PlayResX: 1920');
  buffer.writeln('PlayResY: 1080');
  buffer.writeln('');
  buffer.writeln('[V4+ Styles]');
  buffer.writeln('Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding');
  buffer.writeln('Style: BottomSub,Arial,52,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,1,2,20,20,30,1');
  buffer.writeln('Style: TopSub,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,1,8,20,20,30,1');
  buffer.writeln('');
  buffer.writeln('[Events]');
  buffer.writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text');

  for (final reg in regions) {
    final styleName = reg.id == 'top' ? 'TopSub' : 'BottomSub';
    for (final sub in reg.subs) {
      final startStr = fmtAssTime(sub.start);
      final endStr = fmtAssTime(sub.end);
      final clean = sub.text.replaceAll('\n', '\\N');
      buffer.writeln('Dialogue: 0,$startStr,$endStr,$styleName,,0,0,0,,$clean');
    }
  }
  return buffer.toString();
}

String fmtAssTime(double t) {
  int ms = (t * 1000).round();
  int h = ms ~/ 3600000;
  ms %= 3600000;
  int m = ms ~/ 60000;
  ms %= 60000;
  int s = ms ~/ 1000;
  int cs = (ms % 1000) ~/ 10;
  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
}

// =====================================================================
//  APLIKASI UTAMA
// =====================================================================
void main() => runApp(const HardsubApp());

class HardsubApp extends StatelessWidget {
  const HardsubApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hardsub OCR Smart',
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

  // Multi-region setup
  List<OcrRegion> regions = [
    OcrRegion(id: 'bottom', name: 'Area Utama (Bawah)', yR: const RangeValues(0.72, 0.92), xR: const RangeValues(0.05, 0.95)),
    OcrRegion(id: 'top', name: 'Area Sekunder (Atas)', yR: const RangeValues(0.05, 0.25), xR: const RangeValues(0.05, 0.95), active: false),
  ];

  List<RefSub> refSubs = [];
  String refFileName = '';

  int script = 0;
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
  String filesDir = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      filesDir = await _ch.invokeMethod<String>('dirs') ?? '';
      await _loadSettings();
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

  Future<void> _loadSettings() async {
    final f = File('$filesDir/settings.json');
    if (!await f.exists()) return;
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    script = j['script'] is int ? j['script'] as int : script;
    light = j['light'] is bool ? j['light'] as bool : light;
    bright = j['bright'] is num ? (j['bright'] as num).toDouble() : bright;
    testMode = j['testMode'] is bool ? j['testMode'] as bool : testMode;
    lastUri = j['lastUri'] as String?;
    lastName = (j['lastName'] as String?) ?? '';
  }

  Future<void> _persist() async {
    if (filesDir.isEmpty) return;
    try {
      await File('$filesDir/settings.json').writeAsString(jsonEncode({
        'script': script,
        'light': light,
        'bright': bright,
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
      _snack('Frame gagal: $e');
    }
  }

  Future<void> applyTime() async {
    final t = parseClock(_timeCtl.text);
    if (t == null) {
      _snack('Format waktu salah.');
      return;
    }
    final maxT = math.max(0.0, durMs / 1000.0 - 1);
    setState(() => previewT = t.clamp(0.0, maxT).toDouble());
    _timeCtl.text = fmtClock(previewT);
    await loadPreview();
  }

  Future<void> pickRefSrt() async {
    try {
      final u = await _ch.invokeMethod<String>('pick');
      if (u == null) return;
      // Membaca file referensi SRT
      final file = File(u.replaceAll('file://', ''));
      if (await file.exists()) {
        final content = await file.readAsString();
        refSubs = parseRefSrt(content);
        refFileName = file.path.split('/').last;
        _snack('Subtitle referensi dimuat: ${refSubs.length} baris');
      }
    } catch (e) {
      _snack('Gagal memuat referensi SRT: $e');
    }
  }

  Future<String> _ocrFile(String path, double imgH) async {
    final input = InputImage.fromFilePath(path);
    final lines = <_Ln>[];
    final r = script == 0 ? await _rec.processImage(input) : await _jp.processImage(input);
    for (final b in r.blocks) {
      for (final l in b.lines) {
        lines.add(_Ln(l.text, l.boundingBox));
      }
    }
    return cleanText(lines.map((l) => l.text).join('\n'), script);
  }

  Future<void> testOcr() async {
    if (uri == null) return;
    setState(() => testResult = 'Membaca...');
    try {
      String combined = '';
      for (final reg in regions.where((r) => r.active)) {
        final g = await _ch.invokeMapMethod<String, dynamic>('grab', {
          'timeMs': (previewT * 1000).round(),
          'x0': reg.xR.start,
          'x1': reg.xR.end,
          'y0': reg.yR.start,
          'y1': reg.yR.end,
          'light': light,
          'bright': bright.round(),
          'minFrac': kMinTextFrac,
          'changeFrac': kChangeFrac,
          'force': true,
        });
        if (g != null && g['ok'] == true && g['path'] != null) {
          final txt = await _ocrFile(g['path'] as String, (g['ch'] as num).toDouble());
          if (txt.isNotEmpty) combined += '[${reg.name}] $txt\n';
        }
      }
      setState(() => testResult = combined.isEmpty ? '(kosong)' : combined);
    } catch (e) {
      setState(() => testResult = 'Error: $e');
    }
  }

  Future<void> runOcr() async {
    if (uri == null || running) return;
    final startMs = testMode ? (previewT * 1000).round() : 0;
    final endMs = testMode ? math.min(durMs, startMs + 60000) : durMs;
    final step = (interval * 1000).round();
    final total = ((endMs - startMs) / step).floor();
    if (total <= 0) return;

    setState(() {
      running = true;
      cancel = false;
      progress = 0;
      status = 'Memulai proses Multi-Region OCR...';
    });

    try {
      for (final reg in regions.where((r) => r.active)) {
        reg.samples.clear();
        var currentFrame = 0;
        while (startMs + currentFrame * step < endMs) {
          if (cancel) break;
          final tMs = startMs + currentFrame * step;
          final g = await _ch.invokeMapMethod<String, dynamic>('grab', {
            'timeMs': tMs,
            'x0': reg.xR.start,
            'x1': reg.xR.end,
            'y0': reg.yR.start,
            'y1': reg.yR.end,
            'light': light,
            'bright': bright.round(),
            'minFrac': kMinTextFrac,
            'changeFrac': kChangeFrac,
            'force': false,
          });

          if (g != null && g['ok'] == true && g['path'] != null) {
            final txt = await _ocrFile(g['path'] as String, (g['ch'] as num).toDouble());
            reg.samples.add(Sample(tMs / 1000.0, txt));
          }
          currentFrame++;
          setState(() {
            progress = currentFrame / total;
            status = 'Memproses ${reg.name}: $currentFrame/$total';
          });
        }
        reg.subs = mergeSamples(reg.samples, interval);
      }

      setState(() {
        status = 'Selesai memproses semua area.';
        running = false;
      });
      _tabs.animateTo(2);
    } catch (e) {
      setState(() {
        status = 'Error: $e';
        running = false;
      });
    }
  }

  Future<void> exportFiles(bool isAss) async {
    final allSubs = <Sub>[];
    for (final reg in regions.where((r) => r.active)) {
      allSubs.addAll(reg.subs);
    }
    if (allSubs.isEmpty) {
      _snack('Belum ada subtitle.');
      return;
    }

    final content = isAss ? buildAss(regions) : buildSrt(allSubs);
    final fileName = '${name.split('.').first}.${isAss ? 'ass' : 'srt'}';

    try {
      final where = await _ch.invokeMethod<String>('save', {'name': fileName, 'text': content});
      _snack('Tersimpan di: $where');
    } catch (e) {
      _snack('Gagal ekspor: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hardsub OCR Smart'),
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

  Widget _tabSiapkan() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      _card('1. Video & Referensi', [
        FilledButton.icon(onPressed: running ? null : pickVideo, icon: const Icon(Icons.video_file), label: const Text('Pilih video (MP4 / MKV)')),
        if (uri != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('$name\n${vw}x$vh')),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: pickRefSrt, icon: const Icon(Icons.file_open), label: Text(refFileName.isEmpty ? 'Pilih Subtitle Inggris (Referensi Opsional)' : refFileName)),
      ]),
      if (uri != null) ...[
        _card('2. Pratinjau Waktu', [
          if (previewBytes != null)
            AspectRatio(
              aspectRatio: previewAspect,
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(previewBytes!, fit: BoxFit.fill),
              ]),
            ),
          Row(children: [
            Expanded(child: TextField(controller: _timeCtl, decoration: const InputDecoration(labelText: 'Waktu (menit:detik)'))),
            FilledButton(onPressed: applyTime, child: const Text('Tampilkan')),
          ]),
        ]),
        _card('3. Adaptive Multi-Region OCR', [
          for (var reg in regions)
            CheckboxListTile(
              title: Text(reg.name),
              subtitle: Text('Atas-Bawah: ${reg.yR.start.toStringAsFixed(2)} - ${reg.yR.end.toStringAsFixed(2)}'),
              value: reg.active,
              onChanged: (v) => setState(() => reg.active = v ?? true),
            ),
        ]),
        _card('4. Tes OCR', [
          OutlinedButton.icon(onPressed: testOcr, icon: const Icon(Icons.science), label: const Text('Tes OCR pada waktu ini')),
          if (testResult.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(testResult)),
        ]),
        FilledButton.icon(onPressed: () => _tabs.animateTo(1), icon: const Icon(Icons.arrow_forward), label: const Text('Lanjut ke Proses')),
      ]),
    ]);
  }

  Widget _tabProses() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      _card('Status Proses OCR', [
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 8),
        Text(status),
      ]),
      Row(children: [
        Expanded(child: FilledButton.icon(onPressed: running ? null : runOcr, icon: const Icon(Icons.play_arrow), label: const Text('Mulai OCR'))),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: running ? () => setState(() => cancel = true) : null, child: const Text('Stop')),
      ]),
    ]);
  }

  Widget _tabHasil() {
    final allSubs = <Sub>[];
    for (final reg in regions.where((r) => r.active)) {
      allSubs.addAll(reg.subs);
    }
    return Column(children: [
      Expanded(
        child: allSubs.isEmpty
            ? const Center(child: Text('Belum ada hasil.'))
            : ListView.builder(
                itemCount: allSubs.length,
                itemBuilder: (c, i) {
                  final s = allSubs[i];
                  return ListTile(
                    title: Text(s.text),
                    subtitle: Text('${fmtSrt(s.start)} → ${fmtSrt(s.end)}${s.warn.isEmpty ? '' : ' ⚠ ${s.warn.join(', ')}'}'),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(child: FilledButton(onPressed: () => exportFiles(false), child: const Text('Ekspor SRT'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: () => exportFiles(true), child: const Text('Ekspor ASS'))),
        ]),
      ),
    ]);
  }
}
