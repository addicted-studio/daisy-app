# Public benchmark evidence

These files are published evidence, not a claim that one case represents every
meeting. The first baseline runs Daisy's unmodified product pipeline on the
public AMI `ES2004a` Mix-Headset recording with automatic speaker count.

## AMI ES2004a baseline — 17 August 2026

- Audio: [`ES2004a.Mix-Headset.wav`](https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav)
- Reference: the words-only `ES2004a.rttm` from
  [`pyannote/AMI-diarization-setup`](https://github.com/pyannote/AMI-diarization-setup/blob/main/only_words/rttms/test/ES2004a.rttm),
  committed at `Benchmarks/cases/ami-es2004a/reference.rttm`
- Corpus: [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/),
  distributed under CC BY 4.0
- Audio SHA-256:
  `3e2560b19bee6952c7c7ce041b0f1ea8a7ea9468044c4eea79d2a2c67e24ab0f`
- Environment: MacBook Air `Mac16,13`, Apple M4 10-core, 32 GB;
  macOS 27.0 (`26A5406e`)
- Daisy: 1.0.7.59 build 103; WhisperKit
  `large-v3-v20240930_626MB`; FluidAudio 0.15.4; automatic speaker count

Run the product pipeline and scorer:

```sh
./Benchmarks/run_daisy.sh \
  Benchmarks/datasets/ami/ES2004a.Mix-Headset.wav \
  Benchmarks/reports/public/2026-08-17-ami-es2004a-daisy-hypothesis.json en

./Benchmarks/run_daisy.sh \
  Benchmarks/datasets/ami/ES2004a.Mix-Headset.wav \
  Benchmarks/reports/public/2026-08-17-ami-es2004a-daisy-run-2.json en

./Benchmarks/run_daisy.sh \
  Benchmarks/datasets/ami/ES2004a.Mix-Headset.wav \
  Benchmarks/reports/public/2026-08-17-ami-es2004a-daisy-run-3.json en

python3 Benchmarks/score.py Benchmarks/datasets/ami/manifest.json \
  --json Benchmarks/reports/public/2026-08-17-ami-es2004a.json \
  --markdown Benchmarks/reports/public/2026-08-17-ami-es2004a.md
```

All three runs produced the same 15.68% DER, 20.28% JER, and 4/4 speaker
count. Their RTF values were 0.139×, 0.122×, and 0.107×; the published timing
is the warm median, 0.122×.

This is a diarization-only baseline: AMI's NXT word annotations have not yet
been converted into the benchmark's normalized transcript reference, so WER
and CER are deliberately blank. Humla and OpenWhispr remain blank until their
uncorrected outputs exist for the exact same audio. The full 15/60/180-minute,
EN/RU/mixed, 2/4/6-speaker matrix is still in progress.
