# LUFsync

Two-pass linear loudness normalization for DJ mix libraries, with genre-aware presets, full metadata & cover-art passthrough, and a guided desktop UI.

Created From Fotis Pastrakis
If LUFsync saves you time, consider [buying me a coffee](https://buymeacoffee.com/fotispastrw).

## Why LUFsync exists

Single-pass `loudnorm` actively compresses audio in real time to hit a loudness target - it boosts quiet sections and pulls back loud ones as it goes. That's exactly what destroys macro-dynamics: bass gets bloated, breakdowns and bridges lose their contrast against the rest of the track.

LUFsync uses FFmpeg's **two-pass linear loudnorm** instead:
1. **Pass 1** measures the whole file's integrated loudness (I), true peak (TP), and loudness range (LRA) - no changes are made yet.
2. **Pass 2** applies a single, constant gain calculated from that measurement (`linear=true`) - the same multiplier is applied to the entire waveform, so relative dynamics (quiet vs. loud) are preserved exactly as the source mastered them.

If the required gain would push the true peak past your ceiling, FFmpeg safely falls back to dynamic mode for that file only - LUFsync surfaces this as a warning with the exact numbers, so you can tell a genuine engine limitation apart from a bad/clipped source file.

## Features

- **Two-pass linear loudnorm** - no regression to single-pass dynamic compression.
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

- **Metadata & cover-art passthrough** - title/artist/album/genre/comment tags and embedded artwork survive the re-encode (`-map_metadata 0`, `-map 0:v? -c:v copy`, `-id3v2_version 3`).
- **Batch completion report** - a modal summary of OK / dynamic-fallback-warning / error counts with the affected filenames, shown automatically when a batch finishes.
- **Dark, step-guided UI** - four numbered steps (folders -> genre -> fine-tune -> run), tooltips on every control, live visual feedback when a preset is applied.
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

1. **Step 1** - Browse to your raw tracks folder and choose an output folder.
2. **Step 2** - Click a genre preset button; LUFS/TP/LRA fields update instantly.
3. **Step 3** - Optionally fine-tune the values by hand (this switches the preset selection to "Custom").
4. **Step 4** - Choose whether to force MP3 320k output or keep WAV/FLAC lossless, then press **Start Processing**.

When the batch finishes, a report modal shows how many files normalized cleanly in linear mode versus how many needed a dynamic-mode fallback (usually a sign the source file is already hot/clipped) or failed outright.

## Known limitation

WAV output does not carry cover art (the container format has no video/image stream support). Use FLAC or MP3 output if you need artwork preserved on lossless files.

## License

See [LICENSE](./LICENSE).
