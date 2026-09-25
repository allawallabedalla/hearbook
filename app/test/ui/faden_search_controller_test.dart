// Tests ui/faden_search_controller.dart against fake dependencies (playTone/
// playProbe/stopProbe/onProbeAnswered/onResumeAt/onAborted are all injected
// functions), driven with fake_async so the answer-window timing
// (docs/ARCHITEKTUR.md section 8: probe_len + answer_window = 9 s by default) is exact
// and instant to run. domain/faden_search.dart's own bisection logic is
// already covered by test/domain/faden_search_*.dart -- this file is about
// the *orchestration* around it: progress reporting, PROBE/RESUME wiring,
// abort, and "Früher".

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:faden/domain/faden_search.dart' as fs;
import 'package:faden/ui/faden_search_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder {
  int toneCount = 0;
  final List<int> probesPlayed = [];
  int stopCount = 0;
  final List<({int p, bool known})> probeAnswers = [];
  final List<int> resumeCalls = [];
  final List<({int globalMs, bool recognised})> chosen = [];
  int abortCalls = 0;

  /// Which probe positions the simulated listener "knows" -- knows p iff
  /// p <= knowsUpTo (mirrors the property tests' "kennt p genau dann, wenn
  /// p <= S" listener model, docs/ARCHITEKTUR.md section 8).
  int knowsUpTo = 0;

  FadenSearchController build({
    required int lo,
    required int hi,
    List<int> pausen = const [],
    int? prior,
    bool priorAfterFalseAlarm = false,
    int probeLen = fs.defaultProbeLen,
  }) {
    return FadenSearchController(
      lo: lo,
      hi: hi,
      pausen: pausen,
      prior: prior,
      priorAfterFalseAlarm: priorAfterFalseAlarm,
      probeLen: probeLen,
      onChosen: (globalMs, recognised) async {
        chosen.add((globalMs: globalMs, recognised: recognised));
      },
      playTone: () async {
        toneCount++;
      },
      playProbe: (p) async {
        probesPlayed.add(p);
      },
      stopProbe: () async {
        stopCount++;
      },
      onProbeAnswered: (p, known) async {
        probeAnswers.add((p: p, known: known));
      },
      onResumeAt: (start) async {
        resumeCalls.add(start);
      },
      onAborted: (lastAwake) async {
        abortCalls++;
        resumeCalls.add(lastAwake);
      },
    );
  }
}

/// [values] without consecutive repeats (progress is emitted several times
/// per probe: asked, listening, answered).
List<int> _distinct(Iterable<int> values) {
  final out = <int>[];
  for (final v in values) {
    if (out.isEmpty || out.last != v) out.add(v);
  }
  return out;
}

void main() {
  group('FadenSearchController', () {
    test('a window already <= target resolves immediately with no probes', () {
      fakeAsync((async) {
        final rec = _Recorder();
        final controller = rec.build(lo: 0, hi: fs.target); // exactly at target
        controller.start();
        async.flushMicrotasks();
        expect(rec.toneCount, 0);
        expect(rec.probesPlayed, isEmpty);
        expect(rec.resumeCalls, [0]); // max(lo - preroll, 0) = max(0 - 2000, 0) = 0
        controller.dispose();
      });
    });

    test('no answer ever given: search exhausts and resumes at lo - preroll', () {
      fakeAsync((async) {
        final rec = _Recorder();
        final lo = 5 * 60000, hi = 45 * 60000; // 40 min window, well over target
        final controller = rec.build(lo: lo, hi: hi);
        controller.start();
        async.elapse(const Duration(minutes: 10)); // plenty of time for every probe+timeout
        expect(rec.probeAnswers.every((a) => a.known == false), isTrue);
        expect(rec.probeAnswers, isNotEmpty);
        expect(rec.resumeCalls, [lo - fs.preroll]);
        controller.dispose();
      });
    });

    test('a health-data prior (M6, docs/ARCHITEKTUR.md section 9) reaches fs.fadenSuche: '
        'the first probe lands there, skipping the Fehlalarm-Test', () {
      fakeAsync((async) {
        final rec = _Recorder();
        const lo = 0, hi = 40 * 60000, prior = 5 * 60000;
        final controller = rec.build(lo: lo, hi: hi, prior: prior);
        controller.start();
        async.elapse(const Duration(minutes: 10));
        expect(rec.probesPlayed, isNotEmpty);
        expect(rec.probesPlayed.first, prior); // prior used verbatim, not hi - firstOffset
        controller.dispose();
      });
    });

    test('a learned prior (E78) keeps probe 1 and then lands on the prior', () {
      fakeAsync((async) {
        final rec = _Recorder();
        const lo = 0, hi = 40 * 60000, prior = 5 * 60000;
        final controller = rec.build(lo: lo, hi: hi, prior: prior, priorAfterFalseAlarm: true);
        controller.start();
        async.elapse(const Duration(minutes: 10));
        expect(rec.probesPlayed.take(2), [hi - fs.firstOffset, prior]);
        controller.dispose();
      });
    });

    test('the answer window follows the probe length (E77): 8 s + 3 s', () {
      fakeAsync((async) {
        final rec = _Recorder();
        final controller = rec.build(lo: 0, hi: 40 * 60000, probeLen: 8000);
        controller.start();
        async.elapse(const Duration(milliseconds: 10900));
        expect(rec.probeAnswers, isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(rec.probeAnswers.single.known, isFalse);
        controller.dispose();
      });
    });

    test('onChosen (E79): a recognised passage, then "Früher" down to lo', () {
      fakeAsync((async) {
        final rec = _Recorder();
        const lo = 0, hi = 40 * 60000;
        final controller = rec.build(lo: lo, hi: hi);
        var n = 0;
        controller.progress.listen((p) {
          // "Kenne ich nicht" to probe 1, "kenne ich" to probe 2, then nothing.
          if (p.listening && p.current != null && p.current!.probeNr != n) {
            n = p.current!.probeNr;
            if (n == 1) controller.answer(known: false);
            if (n == 2) controller.answer(known: true);
          }
        });
        controller.start();
        async.elapse(const Duration(minutes: 10));
        expect(rec.chosen, hasLength(1));
        expect(rec.chosen.single.recognised, isTrue);
        expect(rec.chosen.single.globalMs, rec.resumeCalls.single);
        controller.earlier();
        async.flushMicrotasks();
        expect(rec.chosen.last, (globalMs: 0, recognised: false));
        controller.dispose();
      });
    });

    test('onChosen: a recognised probe 1 is a false alarm, not a sleep onset', () {
      fakeAsync((async) {
        final rec = _Recorder();
        final controller = rec.build(lo: 0, hi: 40 * 60000);
        controller.start();
        async.flushMicrotasks();
        controller.submitAnswer();
        async.elapse(const Duration(seconds: 1));
        expect(rec.chosen.single.recognised, isFalse);
        expect(rec.chosen.single.globalMs, 40 * 60000 - fs.firstOffset);
        controller.dispose();
      });
    });

    test('reports progress with an increasing probe number, capped at maxProbes', () {
      fakeAsync((async) {
        final rec = _Recorder();
        final controller = rec.build(lo: 0, hi: 40 * 60000);
        final probeNumbers = <int>[];
        controller.progress.listen((p) => probeNumbers.add(p.probeNr));
        controller.start();
        async.elapse(const Duration(minutes: 10));
        expect(probeNumbers.first, 0); // initial state before probe 1
        expect(_distinct(probeNumbers).skip(1).toList(), List.generate(fs.maxProbes, (i) => i + 1));
        controller.dispose();
      });
    });

    test('an answer inside the probe itself resolves immediately (no timeout wait)', () {
      fakeAsync((async) {
        final rec = _Recorder();
        final controller = rec.build(lo: 0, hi: 40 * 60000);
        controller.start();
        async.flushMicrotasks(); // let the tone + first playProbe call start
        controller.submitAnswer();
        async.elapse(const Duration(seconds: 1));
        expect(rec.probeAnswers.first.known, isTrue);
        controller.dispose();
      });
    });

    test('a probe with no answer within probe_len + answer_window counts as unknown', () {
      fakeAsync((async) {
        final rec = _Recorder();
        final controller = rec.build(lo: 0, hi: 40 * 60000);
        controller.start();
        async.elapse(const Duration(milliseconds: fs.defaultProbeLen + fs.answerWindow - 1));
        expect(rec.probeAnswers, isEmpty); // not yet timed out
        async.elapse(const Duration(milliseconds: 1));
        expect(rec.probeAnswers.single.known, isFalse);
        controller.dispose();
      });
    });

    test('every probe writes exactly one PROBE event via onProbeAnswered', () {
      fakeAsync((async) {
        final rec = _Recorder();
        final controller = rec.build(lo: 0, hi: 40 * 60000);
        controller.start();
        async.elapse(const Duration(minutes: 10));
        expect(rec.probeAnswers.length, rec.probesPlayed.length);
        controller.dispose();
      });
    });

    test('the final result is reported exactly once via onResumeAt (RESUME)', () {
      fakeAsync((async) {
        final rec = _Recorder()..knowsUpTo = 5 * 60000;
        final controller = rec.build(lo: 0, hi: 40 * 60000);
        controller.start();
        // Drive the whole run by always answering "known" when the last
        // probe position is <= knowsUpTo, right when it starts.
        async.flushMicrotasks();
        while (rec.resumeCalls.isEmpty) {
          async.flushMicrotasks();
          if (rec.probesPlayed.isNotEmpty && rec.probeAnswers.length < rec.probesPlayed.length) {
            final p = rec.probesPlayed.last;
            if (p <= rec.knowsUpTo) controller.submitAnswer();
          }
          async.elapse(const Duration(milliseconds: 1));
        }
        expect(rec.resumeCalls, hasLength(1));
        controller.dispose();
      });
    });

    group('explicit answers (E64)', () {
      test('"Kenne ich nicht" answers at once, without waiting for the window', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          controller.start();
          async.elapse(const Duration(seconds: 1));
          controller.answer(known: false);
          async.elapse(const Duration(milliseconds: 10));
          expect(rec.probeAnswers.single.known, isFalse);
          expect(rec.probesPlayed, hasLength(2), reason: 'the next probe follows at once');
          controller.dispose();
        });
      });

      test('only the first answer to a passage counts', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          controller.start();
          async.elapse(const Duration(seconds: 1));
          controller.answer(known: false);
          controller.answer(known: true);
          async.flushMicrotasks();
          expect(rec.probeAnswers, hasLength(1));
          expect(rec.probeAnswers.single.known, isFalse);
          controller.dispose();
        });
      });

      test('the heard list grows by one per probe, each with its answer, after its PROBE is written', () {
        fakeAsync((async) {
          final write = Completer<void>();
          final rec = _Recorder();
          final base = rec.build(lo: 0, hi: 40 * 60000);
          var writes = 0;
          final controller = FadenSearchController(
            lo: base.lo,
            hi: base.hi,
            pausen: base.pausen,
            playTone: base.playTone,
            playProbe: base.playProbe,
            stopProbe: base.stopProbe,
            onProbeAnswered: (p, known) {
              rec.probeAnswers.add((p: p, known: known));
              // The second write is held back.
              return ++writes == 2 ? write.future : Future.value();
            },
            onResumeAt: base.onResumeAt,
            onAborted: base.onAborted,
          );
          final progress = <FadenProgress>[];
          controller.progress.listen(progress.add);
          controller.start();
          async.elapse(const Duration(seconds: 1));
          expect(progress.last.heard, isEmpty);
          expect(progress.last.current?.probeNr, 1);
          expect(progress.last.listening, isTrue);

          controller.answer(known: false);
          async.elapse(const Duration(milliseconds: 10));
          expect(progress.last.heard.map((h) => (h.probeNr, h.known)), [(1, false)]);
          expect(progress.last.hi, rec.probesPlayed.first, reason: 'the thread shrinks: hi moved down');

          controller.answer(known: true);
          async.elapse(const Duration(milliseconds: 10));
          expect(progress.last.heard, hasLength(1), reason: 'not shown as answered before the PROBE is written');
          write.complete();
          async.elapse(const Duration(milliseconds: 10));
          expect(progress.last.heard.map((h) => (h.probeNr, h.known)), [(1, false), (2, true)]);
          expect(progress.last.lo, rec.probesPlayed[1], reason: 'lo moved up to the known probe');
          controller.dispose();
        });
      });

      test('"Nochmal hören" replays the passage and restarts its window; still one answer', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          final windows = <int>[];
          controller.progress.listen((p) => windows.add(p.window));
          controller.start();
          async.elapse(const Duration(seconds: 5));
          final windowBefore = windows.last;
          controller.replay();
          async.flushMicrotasks();
          expect(rec.probesPlayed, hasLength(2));
          expect(rec.probesPlayed[1], rec.probesPlayed[0], reason: 'the same passage again');
          expect(windows.last, windowBefore + 1);

          // 5 s + 6.9 s: past the first window, inside the restarted one.
          async.elapse(const Duration(milliseconds: fs.defaultProbeLen + fs.answerWindow - 100));
          expect(rec.probeAnswers, isEmpty);
          async.elapse(const Duration(milliseconds: 100));
          expect(rec.probeAnswers.single.known, isFalse, reason: 'silence still counts as not known');
          controller.dispose();
        });
      });

      test('an answer after a replay counts once', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          controller.start();
          async.elapse(const Duration(seconds: 2));
          controller.replay();
          controller.replay();
          async.flushMicrotasks();
          controller.answer(known: true);
          async.elapse(const Duration(milliseconds: 10));
          expect(rec.probeAnswers.where((a) => a.p == rec.probesPlayed.first), hasLength(1));
          expect(rec.probeAnswers.first.known, isTrue);
          controller.dispose();
        });
      });

      test('replay and answers outside an answer window do nothing', () {
        fakeAsync((async) {
          final tone = Completer<void>();
          final rec = _Recorder();
          final base = rec.build(lo: 0, hi: 40 * 60000);
          final controller = FadenSearchController(
            lo: base.lo,
            hi: base.hi,
            pausen: base.pausen,
            playTone: () => tone.future,
            playProbe: base.playProbe,
            stopProbe: base.stopProbe,
            onProbeAnswered: base.onProbeAnswered,
            onResumeAt: base.onResumeAt,
            onAborted: base.onAborted,
          );
          controller.start();
          async.flushMicrotasks();
          // The cue tone plays: no window yet.
          controller.answer(known: true);
          controller.replay();
          tone.complete();
          async.flushMicrotasks();
          expect(rec.probesPlayed, hasLength(1));
          async.elapse(const Duration(milliseconds: fs.defaultProbeLen + fs.answerWindow));
          expect(rec.probeAnswers.first.known, isFalse, reason: 'the early "Kenne ich" did not count');
          controller.dispose();
        });
      });
    });

    group('result passages (E64)', () {
      /// Runs a search whose listener knows everything up to [knowsUpTo].
      FadenSearchController runToResult(FakeAsync async, _Recorder rec) {
        final controller = rec.build(lo: 0, hi: 40 * 60000);
        controller.start();
        while (rec.resumeCalls.isEmpty) {
          async.flushMicrotasks();
          if (rec.probesPlayed.isNotEmpty && rec.probeAnswers.length < rec.probesPlayed.length) {
            final p = rec.probesPlayed.last;
            controller.answer(known: p <= rec.knowsUpTo);
          }
          async.elapse(const Duration(milliseconds: 1));
        }
        return controller;
      }

      test('the ladder holds exactly the recognised passages, none later than the result', () {
        fakeAsync((async) {
          final rec = _Recorder()..knowsUpTo = 2000000;
          final controller = runToResult(async, rec);
          final known = [for (final a in rec.probeAnswers) if (a.known) a.p];
          expect(controller.resolved, isTrue);
          expect(controller.leiter.skip(1).toList(), known);
          expect(controller.resultIndex, controller.leiter.length - 1);
          expect(rec.resumeCalls.single, controller.leiter.last);
          for (final p in controller.leiter) {
            expect(p, lessThanOrEqualTo(rec.resumeCalls.single));
          }
          controller.dispose();
        });
      });

      test('a recognised passage resumes there; nothing past the result', () {
        fakeAsync((async) {
          final rec = _Recorder()..knowsUpTo = 2000000;
          final controller = runToResult(async, rec);
          expect(controller.resultIndex, greaterThanOrEqualTo(2), reason: 'setup: several passages known');
          rec.resumeCalls.clear();

          controller.resumeAtLeiterIndex(controller.resultIndex + 1);
          async.flushMicrotasks();
          expect(rec.resumeCalls, isEmpty, reason: 'invariant 9: never later than the result');

          controller.resumeAtLeiterIndex(1);
          async.flushMicrotasks();
          expect(rec.resumeCalls, [controller.leiter[1]]);
          expect(controller.leiterIndex, 1);

          // "Früher" goes on from there; the result stays reachable.
          controller.earlier();
          async.flushMicrotasks();
          expect(rec.resumeCalls.last, fs.positionAtLeiterIndex(controller.leiter, 0));
          controller.resumeAtLeiterIndex(controller.resultIndex);
          async.flushMicrotasks();
          expect(rec.resumeCalls.last, controller.leiter.last);
          controller.dispose();
        });
      });
    });

    group('abort', () {
      test('aborting mid-answer-window resumes at last_awake (lo), not the ladder', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final lo = 3 * 60000;
          final controller = rec.build(lo: lo, hi: 40 * 60000);
          controller.start();
          async.elapse(const Duration(seconds: 1)); // inside the first probe's answer window
          controller.abort();
          async.flushMicrotasks();
          expect(rec.abortCalls, 1);
          expect(rec.resumeCalls, [lo]); // exactly last_awake, no preroll subtracted
          expect(rec.stopCount, greaterThanOrEqualTo(1));
          controller.dispose();
        });
      });

      test('aborting stops the search -- no further probes are played', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          controller.start();
          async.elapse(const Duration(seconds: 1));
          controller.abort();
          async.flushMicrotasks();
          final countAtAbort = rec.probesPlayed.length;
          async.elapse(const Duration(minutes: 5));
          expect(rec.probesPlayed.length, countAtAbort);
        });
      });

      test('abort is idempotent', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          controller.start();
          async.elapse(const Duration(seconds: 1));
          controller.abort();
          controller.abort();
          async.flushMicrotasks();
          expect(rec.abortCalls, 1);
          controller.dispose();
        });
      });
    });

    group('dispose (screen left by back gesture / route pop)', () {
      test('dispose mid-answer-window stops the search: no PROBE, no RESUME, no abort, no error', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          final progress = <FadenProgress>[];
          controller.progress.listen(progress.add);
          controller.start();
          async.elapse(const Duration(seconds: 1)); // inside probe 1's answer window
          expect(rec.probesPlayed, hasLength(1));

          controller.dispose();
          async.elapse(const Duration(minutes: 10));

          expect(rec.probesPlayed, hasLength(1)); // no further probes
          expect(rec.probeAnswers, isEmpty); // no PROBE event for the interrupted probe
          expect(rec.resumeCalls, isEmpty); // no RESUME, no playback start
          expect(rec.abortCalls, 0); // dispose is not a long-press abort
          expect(rec.stopCount, greaterThanOrEqualTo(1)); // probe playback stopped
          expect(_distinct(progress.map((p) => p.probeNr)), [0, 1]);
        });
      });

      test('dispose while the cue tone plays: the probe never starts, no error', () {
        fakeAsync((async) {
          final tone = Completer<void>();
          final rec = _Recorder();
          final base = rec.build(lo: 0, hi: 40 * 60000);
          final controller = FadenSearchController(
            lo: base.lo,
            hi: base.hi,
            pausen: base.pausen,
            playTone: () => tone.future,
            playProbe: base.playProbe,
            stopProbe: base.stopProbe,
            onProbeAnswered: base.onProbeAnswered,
            onResumeAt: base.onResumeAt,
            onAborted: base.onAborted,
          );
          controller.start();
          async.flushMicrotasks();
          controller.dispose();
          tone.complete();
          async.elapse(const Duration(minutes: 10));
          expect(rec.probesPlayed, isEmpty);
          expect(rec.probeAnswers, isEmpty);
          expect(rec.resumeCalls, isEmpty);
          expect(rec.abortCalls, 0);
        });
      });

      test('an answer racing dispose is dropped (lo never moves without a recorded answer)', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          controller.start();
          async.elapse(const Duration(seconds: 1));
          controller.submitAnswer(); // completes the pending answer ...
          controller.dispose(); // ... but the screen is gone before it is handled
          async.elapse(const Duration(minutes: 10));
          expect(rec.probeAnswers, isEmpty);
          expect(rec.resumeCalls, isEmpty);
          expect(rec.probesPlayed, hasLength(1));
        });
      });

      test('dispose while a PROBE write is in flight: no next probe, no RESUME, no error', () {
        fakeAsync((async) {
          final write = Completer<void>();
          final rec = _Recorder();
          final base = rec.build(lo: 0, hi: 40 * 60000);
          final controller = FadenSearchController(
            lo: base.lo,
            hi: base.hi,
            pausen: base.pausen,
            playTone: base.playTone,
            playProbe: base.playProbe,
            stopProbe: base.stopProbe,
            onProbeAnswered: (p, known) {
              rec.probeAnswers.add((p: p, known: known));
              return write.future;
            },
            onResumeAt: base.onResumeAt,
            onAborted: base.onAborted,
          );
          controller.start();
          async.elapse(const Duration(milliseconds: fs.defaultProbeLen + fs.answerWindow)); // times out
          expect(rec.probeAnswers, hasLength(1));
          controller.dispose();
          write.complete();
          async.elapse(const Duration(minutes: 10));
          expect(rec.probesPlayed, hasLength(1));
          expect(rec.probeAnswers, hasLength(1));
          expect(rec.resumeCalls, isEmpty);
          expect(rec.abortCalls, 0);
        });
      });

      test('dispose after the result: "Früher" is a no-op, no error', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: fs.target);
          controller.start();
          async.flushMicrotasks();
          expect(rec.resumeCalls, hasLength(1));
          controller.dispose();
          controller.earlier();
          controller.submitAnswer();
          controller.abort();
          async.elapse(const Duration(minutes: 1));
          expect(rec.resumeCalls, hasLength(1));
          expect(rec.abortCalls, 0);
        });
      });

      test('dispose is idempotent', () {
        fakeAsync((async) {
          final rec = _Recorder();
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          controller.start();
          async.elapse(const Duration(seconds: 1));
          controller.dispose();
          controller.dispose();
          async.elapse(const Duration(minutes: 1));
          expect(rec.resumeCalls, isEmpty);
        });
      });
    });

    group('earlier ("Früher")', () {
      test('steps back through the ladder one entry at a time via onResumeAt', () {
        fakeAsync((async) {
          // knowsUpTo is chosen so the first ("Fehlalarm-Test") probe is
          // answered "no" (it sits close to hi) but several later,
          // successively closer bisection probes are answered "yes" --
          // otherwise a "yes" on probe 1 ends the search immediately with
          // a 2-entry ladder (domain/faden_search.dart's early return).
          final rec = _Recorder()..knowsUpTo = 2000000;
          final controller = rec.build(lo: 0, hi: 40 * 60000);
          controller.start();
          while (rec.resumeCalls.isEmpty) {
            async.flushMicrotasks();
            if (rec.probesPlayed.isNotEmpty && rec.probeAnswers.length < rec.probesPlayed.length) {
              final p = rec.probesPlayed.last;
              if (p <= rec.knowsUpTo) controller.submitAnswer();
            }
            async.elapse(const Duration(milliseconds: 1));
          }
          rec.resumeCalls.clear();
          expect(controller.canGoEarlier, isTrue,
              reason: 'test setup should have produced a multi-entry ladder');

          final seen = <int>[];
          while (controller.canGoEarlier) {
            final before = rec.resumeCalls.length;
            controller.earlier();
            async.flushMicrotasks();
            expect(rec.resumeCalls.length, before + 1); // exactly one more RESUME per step
            seen.add(rec.resumeCalls.last);
          }
          expect(seen.toSet().length, seen.length); // every ladder step is a distinct position

          // Once at the ladder's first entry, further taps are a no-op.
          final countAtStart = rec.resumeCalls.length;
          controller.earlier();
          async.flushMicrotasks();
          expect(rec.resumeCalls.length, countAtStart);
          controller.dispose();
        });
      });

      test('canGoEarlier is false at the ladder\'s first entry, and earlier() is then a no-op', () {
        fakeAsync((async) {
          final rec = _Recorder();
          // A window already <= target never plays a probe, so the ladder
          // is just [lo] -- nothing to step back to.
          final controller = rec.build(lo: 0, hi: fs.target);
          controller.start();
          async.flushMicrotasks();
          expect(controller.canGoEarlier, isFalse);
          controller.earlier();
          async.flushMicrotasks();
          expect(rec.resumeCalls, hasLength(1)); // only the original result
          controller.dispose();
        });
      });
    });
  });
}
