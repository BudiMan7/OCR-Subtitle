import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hardsub_ocr/algo.dart';

const double iv = 0.33;

const sentences = [
  'Kita punya transfer anggota dari bagian akuntansi ke pasukan tempur.',
  'Aku tidak tahu apa yang harus kulakukan sekarang.',
  'Ya.',
  'Tunggu dulu, jangan pergi sendirian.',
  'Bagaimana kalau kita coba lagi besok pagi?',
  'Kapten sudah menunggu di ruang kendali.',
  'Jangan khawatir, semuanya akan baik-baik saja.',
  'Kami harus segera berangkat sebelum malam tiba.',
];

Cand subCand(String text, {double y = 0.80, double h = 0.05}) => Cand(text, 0.15, y, 0.85, y + h, outline: 0.85, fill: 0.3);

class Ev {
  final double start, end;
  final List<Cand> cands;
  Ev(this.start, this.end, this.cands);
}

List<Sample> makeSamples(List<Ev> events, double total,
    {List<Ev> noise = const [], Set<int> failAt = const {}, Map<int, String Function(String)> partial = const {}}) {
  final out = <Sample>[];
  final n = (total / iv).floor();
  for (var k = 0; k < n; k++) {
    final t = k * iv;
    var cands = <Cand>[];
    for (final e in [...events, ...noise]) {
      if (e.start <= t && t < e.end) cands.addAll(e.cands.map((c) => c.copy()));
    }
    if (failAt.contains(k)) cands = cands.where((c) => c.t < 0.7).toList();
    final p = partial[k];
    if (p != null) {
      for (final c in cands) {
        if (c.t >= 0.7) {
          c.text = p(c.text);
          c.r = c.l + (c.r - c.l) * 0.5;
        }
      }
    }
    out.add(Sample((t * 1000).round() / 1000, cands));
  }
  return out;
}

List<Sub> subsOf(List<Sample> s) => tracksToSubs(buildTracks(s, iv), iv);

Sub mk(double s, double e, String t, {int cls = 0}) {
  final x = Sub(s, e, t);
  x.cls = cls;
  x.box = [0.1, 0.8, 0.9, 0.86];
  x.score = 0.9;
  return x;
}

void main() {
  test('parse & bangun SRT', () {
    final src = '${String.fromCharCode(0xFEFF)}1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i> there\r\n\r\n2\r\n00:01:02.5 --> 00:01:04.000\r\n{\\an8}Second\r\nline\r\n\r\n';
    final c = parseSrtFile(src);
    expect(c.length, 2);
    expect(c[0].text, 'Hello there');
    expect(c[1].start, closeTo(62.5, 1e-9));
    expect(c[1].text, 'Second\nline');
    final s = mk(1, 2, 'Teks');
    final d = mk(3, 4, 'Ragu', cls: 1);
    expect('-->'.allMatches(buildSrt([s, d])).length, 1);
    expect('-->'.allMatches(buildSrt([s, d], includeDoubtful: true)).length, 2);
  });

  test('filter: tulisan di benda (O5Mo, YAMY) bukan subtitle; "Ya." tetap diterima', () {
    final ev = <Ev>[];
    var t = 2.0;
    for (var i = 0; i < 24; i++) {
      ev.add(Ev(t, t + 2.5, [subCand(sentences[i % sentences.length])]));
      t += 3.5;
    }
    final noise = [
      Ev(0, 100, [
        Cand('O5Mo', 0.30, 0.45, 0.36, 0.49, outline: 0.2, fill: 0.5),
        Cand('YAMY', 0.62, 0.47, 0.69, 0.51, outline: 0.25, fill: 0.5),
      ])
    ];
    final subs = subsOf(makeSamples(ev, 90, noise: noise));
    final o5 = subs.firstWhere((s) => s.text == 'O5Mo');
    final ya = subs.firstWhere((s) => s.text == 'YAMY');
    expect(o5.cls, clsNon);
    expect(ya.cls, isNot(clsLikely));
    final good = subs.where((s) => sentences.contains(s.text)).toList();
    expect(good.length, 24);
    expect(good.every((s) => s.cls == clsLikely), isTrue);
    expect(good.where((s) => s.text == 'Ya.').every((s) => s.cls == clsLikely), isTrue);
  });

  test('subtitle pendek dan OCR gagal 2 frame tidak memecah subtitle', () {
    final ev = <Ev>[];
    var t = 1.0;
    for (var i = 0; i < 10; i++) {
      ev.add(Ev(t, t + 2.0, [subCand(sentences[i % sentences.length])]));
      t += 3.0;
    }
    ev.add(Ev(40.0, 41.0, [subCand('Ya.')]));
    final subs = subsOf(makeSamples(ev, 60, failAt: {6, 7}));
    expect(subs.where((s) => s.text == sentences[0] && s.start < 10).length, 1);
    expect(subs.any((s) => s.text == 'Ya.' && s.start > 39 && s.cls == clsLikely), isTrue);
  });

  test('teks terpotong sesaat dilengkapi frame lain; tidak mengarang', () {
    const full = 'Kita punya transfer anggota dari bagian akuntansi ke pasukan tempur.';
    String cut(String s) => s.substring(0, 30);
    var subs = subsOf(makeSamples([Ev(5.0, 8.0, [subCand(full)])], 12, partial: {15: cut, 16: cut, 17: cut}));
    final real = subs.where((s) => s.cls != clsNon).toList();
    expect(real.length, 1);
    expect(real[0].text, full);
    // semua frame terpotong: tidak ada bukti teks lengkap -> teks asli dipertahankan
    subs = subsOf(makeSamples([Ev(5.0, 8.0, [subCand(full)])], 12, partial: {for (var k = 15; k < 24; k++) k: cut}));
    final r = subs.where((s) => s.cls != clsNon).first;
    expect(r.text.length, lessThanOrEqualTo(30));
  });

  test('dua subtitle di posisi berbeda tampil bersamaan', () {
    final top = Cand('Dialog atas yang cukup panjang di sini.', 0.2, 0.08, 0.8, 0.13, outline: 0.8, fill: 0.3);
    final bot = subCand('Dialog bawah yang juga panjang di sini.');
    final subs = subsOf(makeSamples([Ev(2.0, 6.0, [top, bot])], 10));
    expect(subs.length, 2);
    expect((subs[0].start - subs[1].start).abs(), lessThan(0.5));
  });

  test('blok: dua baris jadi satu subtitle; potongan kiri-kanan digabung', () {
    final l1 = Cand('Baris pertama dari kalimat panjang', 0.2, 0.80, 0.8, 0.85, outline: 0.8, fill: 0.3);
    final l2 = Cand('dan baris kedua yang melengkapinya.', 0.2, 0.86, 0.8, 0.91, outline: 0.8, fill: 0.3);
    var subs = subsOf(makeSamples([Ev(2.0, 6.0, [l1, l2])], 9));
    expect(subs.length, 1);
    expect('\n'.allMatches(subs[0].text).length, 1);
    final a = Cand('Kita punya transfer anggota', 0.10, 0.80, 0.45, 0.85, outline: 0.8, fill: 0.3);
    final b = Cand('dari bagian akuntansi', 0.47, 0.80, 0.9, 0.85, outline: 0.8, fill: 0.3);
    subs = subsOf(makeSamples([Ev(2.0, 6.0, [a, b])], 9));
    expect(subs.length, 1);
    expect(subs[0].text, 'Kita punya transfer anggota dari bagian akuntansi');
  });

  // ---- referensi ----
  List<Cue> makeRef({int n = 120, int seed = 3}) {
    final rnd = math.Random(seed);
    final cues = <Cue>[];
    var t = 10.0;
    for (var i = 0; i < n; i++) {
      final dur = 1.2 + rnd.nextDouble() * 3.3;
      final words = 2 + rnd.nextInt(9);
      final en = List.generate(words, (_) => 'word${rnd.nextInt(99)}').join(' ');
      cues.add(Cue(t, t + dur, en));
      t += dur + 0.2 + rnd.nextDouble() * 3.8;
    }
    return cues;
  }

  List<Sub> ocrFromRef(List<Cue> cues, double off, List<int> truth,
      {double jitter = 0.25, double drop = 0.1, int seed = 5, int shiftAfter = -1, double shift = 0}) {
    final rnd = math.Random(seed);
    final subs = <Sub>[];
    for (var j = 0; j < cues.length; j++) {
      if (rnd.nextDouble() < drop) continue;
      final c = cues[j];
      final o = off + (shiftAfter >= 0 && j >= shiftAfter ? shift : 0.0);
      final words = math.max(2, (c.text.split(' ').length * 1.1).floor());
      final s = mk(c.start - o + (rnd.nextDouble() * 2 - 1) * jitter, c.end - o + (rnd.nextDouble() * 2 - 1) * jitter,
          List.generate(words, (_) => 'kata${rnd.nextInt(99)}').join(' '));
      subs.add(s);
      truth.add(j);
    }
    return subs;
  }

  test('offset global terdeteksi; video yang tidak berhubungan tidak divalidasi', () {
    final cues = makeRef();
    final truth = <int>[];
    final subs = ocrFromRef(cues, 3.2, truth);
    final info = estimateOffset(subs, cues)!;
    expect(info.ok, isTrue);
    expect(info.offset, closeTo(3.2, 0.3));
    final rnd = math.Random(9);
    final junk = <Sub>[];
    var t = 5.0;
    for (var i = 0; i < 80; i++) {
      final d = 1 + rnd.nextDouble() * 2;
      junk.add(mk(t, t + d, 'abc def ghi'));
      t += d + 0.3 + rnd.nextDouble() * 4.7;
    }
    expect(estimateOffset(junk, cues)!.ok, isFalse);
  });

  test('pencocokan urutan: benar, tahan dialog hilang, geser lokal, sampah tidak dipaksa', () {
    final cues = makeRef();
    final truth = <int>[];
    final subs = ocrFromRef(cues, 3.2, truth, shiftAfter: 60, shift: 1.2);
    final gt = <Sub, int>{for (var i = 0; i < subs.length; i++) subs[i]: truth[i]};
    final rnd = math.Random(1);
    final junk = <Sub>[];
    for (var k = 0; k < 5; k++) {
      final st = 20 + rnd.nextDouble() * 280;
      final s = mk(st, st + 1.5, 'xyzzy abc', cls: 1);
      s.score = 0.5;
      s.box = [0.2, 0.5, 0.3, 0.55];
      junk.add(s);
      subs.add(s);
    }
    subs.sort((a, b) => a.start.compareTo(b.start));
    clearReference(subs);
    final r = matchReference(subs, cues);
    applyReference(subs, cues, r, timeline: 0);
    var ok = 0, bad = 0;
    for (final s in subs) {
      final g = gt[s];
      if (s.cls == clsMissing || g == null) continue;
      if (s.refStart != null && (s.refStart! - cues[g].start).abs() < 1e-6) {
        ok++;
      } else {
        bad++;
      }
    }
    expect(ok / (ok + bad), greaterThanOrEqualTo(0.93));
    for (final j in junk) {
      expect(j.cls, isNot(clsLikely));
    }
    final sure = subs.where((s) => s.cls != clsMissing && gt[s] != null && s.pair >= 0.65);
    expect(sure.isNotEmpty, isTrue);
    for (final s in sure) {
      expect((s.start - s.refStart!).abs(), lessThan(1e-6));
    }
    expect(subs.where((s) => s.cls == clsMissing).length, greaterThan(0));
    expect(r.driftMax - r.driftMin, greaterThan(0.5)); // geser lokal terdeteksi
  });

  test('satu cue dipecah dua OCR, dua cue digabung satu OCR', () {
    final cues = List.generate(20, (i) => Cue(10.0 + i * 5, 13.0 + i * 5, 'english line number $i here'));
    final subs = <Sub>[];
    for (var i = 0; i < cues.length; i++) {
      final c = cues[i];
      if (i == 7) {
        subs.add(mk(c.start - 2, c.start - 2 + 1.4, 'kalimat indonesia bagian satu'));
        subs.add(mk(c.start - 2 + 1.5, c.end - 2, 'bagian dua nya'));
      } else if (i == 12) {
        subs.add(mk(c.start - 2, cues[13].end - 2, 'kalimat indonesia gabungan dua cue sekaligus ya'));
      } else if (i == 13) {
        continue;
      } else {
        subs.add(mk(c.start - 2, c.end - 2, 'teks indonesia nomor $i di sini'));
      }
    }
    clearReference(subs);
    applyReference(subs, cues, matchReference(subs, cues), timeline: 0);
    final by = {for (final s in subs) s.text: s};
    final a = by['kalimat indonesia bagian satu']!;
    final b = by['bagian dua nya']!;
    expect(a.warn.contains('split2'), isTrue);
    expect(a.start, closeTo(45.0, 1e-6));
    expect(b.end, closeTo(48.0, 1e-6));
    expect(a.end, lessThanOrEqualTo(b.start + 1e-6));
    final g = by['kalimat indonesia gabungan dua cue sekaligus ya']!;
    expect(g.warn.contains('span2'), isTrue);
    expect(g.start, closeTo(70.0, 1e-6));
    expect(g.end, closeTo(78.0, 1e-6));
    expect(subs.where((s) => s.cls == clsMissing).length, 0);
  });

  test('garis waktu video: waktu OCR dirapikan referensi, tidak berubah jauh; penerapan ulang tidak menumpuk', () {
    final cues = makeRef();
    final truth = <int>[];
    final subs = ocrFromRef(cues, 3.2, truth, jitter: 0.3);
    final before = subs.map((s) => s.start).toList();
    for (var rep = 0; rep < 2; rep++) {
      clearReference(subs);
      applyReference(subs, cues, matchReference(subs, cues), timeline: 1);
    }
    var maxD = 0.0;
    for (var i = 0; i < subs.length; i++) {
      maxD = math.max(maxD, (subs[i].start - before[i]).abs());
    }
    expect(maxD, lessThan(1.0));
    clearReference(subs);
    for (var i = 0; i < subs.length; i++) {
      expect(subs[i].start, closeTo(before[i], 1e-9));
    }
  });

  test('cue referensi di luar rentang OCR tidak dianggap hilang', () {
    final cues = makeRef(n: 60);
    final truth = <int>[];
    var subs = ocrFromRef(cues, 0.0, truth, drop: 0.0);
    subs = subs.where((s) => s.end < 100).toList();
    clearReference(subs);
    applyReference(subs, cues, matchReference(subs, cues), timeline: 0, covLo: 0, covHi: 100);
    expect(subs.where((s) => s.cls == clsMissing && s.refStart! > 110).length, 0);
  });

  test('pemulihan teks terpotong hanya dengan bukti', () {
    const full = 'Kita punya transfer anggota dari bagian akuntansi ke pasukan tempur.';
    const cur = 'Kita punya transfer anggota dari';
    expect(pickRecovered(cur, [cur, full, full, cur]), full);
    expect(pickRecovered(cur, [cur, full]), isNull);
    expect(pickRecovered(cur, ['$cur 12345 @@@', '$cur 12345 @@@']), isNull);
  });

  test('ASS valid: gaya, posisi, dua subtitle bersamaan', () {
    final a = mk(1, 3, 'Bawah');
    final b = mk(1, 3, 'Atas {x}');
    b.box = [0.2, 0.08, 0.8, 0.13];
    b.area = 1;
    final out = buildAss([a, b], width: 1280, height: 720);
    expect(out.contains('[Script Info]'), isTrue);
    expect(out.contains('PlayResX: 1280'), isTrue);
    expect('Style: '.allMatches(out).length, 2);
    expect('Dialogue: '.allMatches(out).length, 2);
    expect(out.contains(r'\an2\pos(640,'), isTrue);
    expect(out.contains('Atas (x)'), isTrue);
    expect(out.contains('0:00:01.00,0:00:03.00'), isTrue);
  });

  test('simpan & muat Sub (JSON) termasuk data lama', () {
    final s = mk(1, 2, 'Teks');
    s.refText = 'Hello';
    s.pair = 0.8;
    final j = s.toJson();
    final back = Sub.fromJson(j);
    expect(back.refText, 'Hello');
    expect(back.pair, 0.8);
    final old = Sub.fromJson({'start': 1, 'end': 2, 'text': 'x', 'warn': ['hanya terbaca 1 kali']});
    expect(old.cls, clsLikely);
  });
}
