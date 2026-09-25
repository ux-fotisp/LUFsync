# LUFsync

Two-pass linear loudness normalization for DJ mix libraries, with genre-aware presets, automatic peak-safe clamping, full metadata & cover-art passthrough, and a guided black/red desktop UI.

Created From Fotis Pastrakis
If LUFsync saves you time, consider [supporting via PayPal](https://paypal.me/fotisps1).

## Why LUFsync exists

Single-pass `loudnorm` actively compresses audio in real time to hit a loudness target - it boosts quiet sections and pulls back loud ones as it goes. That destroys macro-dynamics: bass gets bloated, breakdowns and bridges lose their contrast against the rest of the track.

LUFsync uses FFmpeg's **two-pass linear loudnorm** instead:
1. **Pass 1** measures the whole file's integrated loudness (I), true peak (TP), and loudness range (LRA) - no changes are made yet.
2. **Pass 2** applies a single, constant gain calculated from that measurement (`linear=true`) - the same multiplier is applied to the entire waveform, so relative dynamics (quiet vs. loud) are preserved exactly as the source mastered them.

## Compute-then-clamp: never falls back to real compression

FFmpeg's `loudnorm` can silently revert to **dynamic mode** (a real adaptive compressor) when linear mode is mathematically infeasible for a file. This happens for two independent reasons:

- **True-peak ceiling**: the gain needed to hit your target loudness would push the file's peak past the TP ceiling.
- **LRA is scale-invariant**: a constant gain cannot shrink a track's natural loudness range. If a file's LRA already exceeds your target LRA, no linear gain can satisfy that target - only real compression can.

LUFsync avoids this by **pre-computing the maximum safe linear target per file** from the Pass 1 measurement, before ever calling Pass 2:

```
effectiveI   = min(presetI, measuredI + (targetTP - measuredTP))
effectiveLRA = max(presetLRA, measuredLRA)
```

These clamped, guaranteed-achievable numbers are what actually get sent to FFmpeg - so dynamic-mode fallback should be structurally unreachable. If a file's source is already hot/clipped, LUFsync will quietly reduce its target loudness (sometimes even below the source's original level) rather than risk further clipping or compression. Every clamp is logged explicitly so you know exactly which files play quieter than the rest of your set and why.

## Features

- **Two-pass linear loudnorm** with compute-then-clamp safety - no regression to single-pass dynamic compression, ever.
- **Genre presets** (click-to-apply, tuned for club/DJ playback, not streaming):

  | Genre | LUFS | TP | LRA |
  |---|---|---|---|
  | Hip Hop | -8.0 | -1.0 | 9 |
  | EDM / Dance | -7.0 | -1.0 | 7 |
  | Pop | -9.0 | -1.0 | 8 |
  | Rock | -10.0 | -1.0 | 10 |
  | Metal | -8.0 | -1.0 | 7 |
  | House / Techno | -7.0 | -1.0 | 7 |
  | Trance | -8.0 | -1.0 | 9 |
  | Folk / Balkan / Greek | -12.0 | -1.0 | 12 |

- **Analyze Only mode** - runs Pass 1 measurement across a whole folder (writes nothing) and exports a CSV of every file's measured I/TP/LRA/crest factor, so you can calibrate genre presets against your real library instead of literature defaults.
- **Metadata & cover-art passthrough** - title/artist/album/genre/comment tags and embedded artwork survive the re-encode (`-map_metadata 0`, `-map 0:v? -c:v copy`, `-id3v2_version 3`).
- **Batch completion report** - a modal summary of OK / unexpected-fallback / error counts with affected filenames, shown automatically when a batch finishes.
- **Black/red editorial UI** - step-guided sections (folders -> genre -> fine-tune -> run), tooltips on every control, live visual feedback when a preset is applied, an enlarged Start Processing button, and a roomy live log panel for watching the batch progress in real time.
- **Locale-safe & Unicode-safe** - numeric arguments are always formatted with invariant (period) decimals regardless of Windows locale, and the FFmpeg command line is built with proper Win32 argument escaping, so filenames with spaces, parentheses, or Greek/Balkan characters are handled correctly.

## Requirements

- Windows 10/11 (PowerShell 5.1, included by default)
- [FFmpeg](https://ffmpeg.org/download.html) installed and available on `PATH`

## Installation

1. Install FFmpeg and confirm it's on PATH:
   ```
   ffmpeg -version
   ```
2. Download `LUFsync.ps1` from this repository.
3. Run it. If Windows blocks the script (unsigned-script execution policy), use one of:

   ```powershell
   # One-off run, no lasting policy change:
   powershell.exe -ExecutionPolicy Bypass -File "LUFsync.ps1"

   # Or unblock the downloaded file once, then run normally:
   Unblock-File -Path "LUFsync.ps1"
   .\LUFsync.ps1
   ```

## Usage

1. **Step 1 - Folders**: browse to your raw tracks folder and choose an output folder.
2. **Step 2 - Genre Preset**: click a genre button; LUFS/TP/LRA fields update instantly.
3. **Step 3 - Fine-Tune**: optionally hand-edit the values (this switches the preset selection to "Custom").
4. **Step 4 - Run**: optionally check "Analyze Only" to measure your library first without writing anything, choose whether to force MP3 320k output or keep WAV/FLAC lossless, then press **Start Processing**.

When a normalization batch finishes, a report modal shows how many files normalized cleanly in linear mode versus how many needed an unexpected fallback or failed outright. When an Analyze Only run finishes, a modal shows the min/max/avg LUFS/TP/LRA/crest-factor across the analyzed folder and the path to the exported CSV.

## Known limitation

WAV output does not carry cover art (the container format has no video/image stream support). Use FLAC or MP3 output if you need artwork preserved on lossless files.

## License

See [LICENSE](./LICENSE).
