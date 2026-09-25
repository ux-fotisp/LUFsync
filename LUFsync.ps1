Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# LUFsync
# Two-pass FFmpeg loudnorm (linear=true) DJ mix batch normalizer.
# Genre presets, metadata/artwork passthrough, dark step-guided UI,
# completion report modal.
#
# Created by Fotis Pastrakis
# https://buymeacoffee.com/fotispastrw
#
# v9 (LUFsync 1.0): Rebranded. Added a batch-completion report modal
# (counts of linear-OK / dynamic-fallback-WARN / ERROR files, with file
# lists) and a credit + Buy Me a Coffee link in the header. Processing
# engine unchanged from v8 (confirmed working two-pass pipeline).
# ---------------------------------------------------------------------------

$inv = [System.Globalization.CultureInfo]::InvariantCulture

$syncHash = [hashtable]::Synchronized(@{
    Log        = New-Object System.Collections.Generic.Queue[string]
    Progress   = 0
    Total      = 0
    Running    = $false
    Cancel     = $false
    OKCount    = 0
    WarnCount  = 0
    ErrorCount = 0
    WarnFiles  = New-Object System.Collections.Generic.List[string]
    ErrorFiles = New-Object System.Collections.Generic.List[string]
})

$genrePresets = [ordered]@{
    "Hip Hop"               = @(-8.0, -1.0, 9)
    "EDM / Dance"           = @(-7.0, -1.0, 7)
    "Pop"                   = @(-9.0, -1.0, 8)
    "Rock"                  = @(-10.0, -1.0, 10)
    "Metal"                 = @(-8.0, -1.0, 7)
    "House / Techno"        = @(-7.0, -1.0, 7)
    "Trance"                = @(-8.0, -1.0, 9)
    "Folk / Balkan / Greek" = @(-12.0, -1.0, 12)
}

$workerScript = {
    param($inputDir, $outputDir, $targetLUFS, $truePeak, $loudnessRange, $forceMp3, $syncHash)

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    function Log($msg) { $syncHash.Log.Enqueue($msg) }

    $lufsStr = ([double]$targetLUFS).ToString("0.0", $inv)
    $tpStr   = ([double]$truePeak).ToString("0.0", $inv)
    $lraStr  = ([double]$loudnessRange).ToString("0", $inv)

    function ConvertTo-Win32Arg {
        param([string]$Arg)
        if ($Arg -eq "") { return '""' }
        if ($Arg -notmatch '[\s"]') { return $Arg }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $backslashes = 0
        foreach ($ch in $Arg.ToCharArray()) {
            if ($ch -eq '\') { $backslashes++; continue }
            if ($ch -eq '"') {
                [void]$sb.Append('\' * ($backslashes * 2 + 1))
                [void]$sb.Append('"')
                $backslashes = 0
            } else {
                if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
                [void]$sb.Append($ch)
            }
        }
        if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
        [void]$sb.Append('"')
        return $sb.ToString()
    }

    function Invoke-FFmpegCapture {
        param([string[]]$ArgList)
        $commandLine = ($ArgList | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' '
        Log "DEBUG | ffmpeg $commandLine"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = "ffmpeg"
        $psi.Arguments = $commandLine
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true

        try { $proc = [System.Diagnostics.Process]::Start($psi) }
        catch { return @{ ExitCode = -1; Output = ""; StdOut = ""; LaunchError = $_.Exception.Message } }

        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $proc.WaitForExit()

        return @{ ExitCode = $proc.ExitCode; Output = $stderrTask.Result; StdOut = $stdoutTask.Result; LaunchError = $null }
    }

    function Get-ErrorSnippet($text) {
        if ([string]::IsNullOrWhiteSpace($text)) { return "(no stderr output)" }
        $lines = $text -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
        return (($lines | Select-Object -Last 5) -join " | ")
    }

    if (!(Test-Path -Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }

    $files = Get-ChildItem -Path $inputDir -Include *.mp3, *.wav, *.flac -Recurse
    $syncHash.Total = $files.Count
    $count = 0

    foreach ($file in $files) {
        if ($syncHash.Cancel) { Log "CANCELLED: Batch stopped by user."; break }
        $count++
        $syncHash.Progress = $count

        $relativeDir = Split-Path -Path (Resolve-Path -Relative -Path $file.FullName -RelativeBasePath $inputDir) -Parent
        $destDir = Join-Path -Path $outputDir -ChildPath $relativeDir
        if (!(Test-Path -Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        $ext = $file.Extension.ToLower()
        if ($forceMp3) {
            $outputExt = ".mp3"; $codecArgs = @("-c:a", "libmp3lame", "-b:a", "320k")
        } else {
            switch ($ext) {
                ".wav"  { $outputExt = ".wav";  $codecArgs = @("-c:a", "pcm_s24le") }
                ".flac" { $outputExt = ".flac"; $codecArgs = @("-c:a", "flac") }
                default { $outputExt = ".mp3";  $codecArgs = @("-c:a", "libmp3lame", "-b:a", "320k") }
            }
        }
        $outputFile = Join-Path -Path $destDir -ChildPath ($file.BaseName + $outputExt)

        Log "STAGE1 | Measuring: $($file.Name)"

        $pass1Args = @(
            "-y", "-hide_banner", "-i", $file.FullName, "-vn",
            "-af", "loudnorm=I=${lufsStr}:TP=${tpStr}:LRA=${lraStr}:print_format=json",
            "-f", "null", "-"
        )
        $pass1Result = Invoke-FFmpegCapture -ArgList $pass1Args

        if ($pass1Result.LaunchError) {
            Log "ERROR | Could not launch FFmpeg: $($pass1Result.LaunchError)"
            $syncHash.ErrorCount++; $syncHash.ErrorFiles.Add($file.Name)
            continue
        }

        $pass1 = $pass1Result.Output
        if ([string]::IsNullOrWhiteSpace($pass1)) {
            Log "ERROR | $($file.Name): FFmpeg produced no stderr output (exit $($pass1Result.ExitCode))."
            $syncHash.ErrorCount++; $syncHash.ErrorFiles.Add($file.Name)
            continue
        }

        if ($pass1 -match '(?s)\{[^{}]*"input_i"[^{}]*\}') {
            try { $stats = $Matches[0] | ConvertFrom-Json } catch {
                Log "ERROR | JSON parse failed for $($file.Name): $($_.Exception.Message)"
                $syncHash.ErrorCount++; $syncHash.ErrorFiles.Add($file.Name)
                continue
            }
            if ([string]::IsNullOrWhiteSpace($stats.input_i)) {
                Log "ERROR | $($file.Name): Pass 1 returned no input_i value. Skipping."
                $syncHash.ErrorCount++; $syncHash.ErrorFiles.Add($file.Name)
                continue
            }

            $originalI  = [double]$stats.input_i
            $originalTP = [double]$stats.input_tp
            $gainOffset = [math]::Round(([double]$lufsStr) - $originalI, 2)
            $direction  = if ($gainOffset -gt 0) { "BOOSTED" } else { "REDUCED" }
            Log "INFO | $($file.Name): $direction by $gainOffset dB (measured $originalI LUFS, peak $originalTP dBTP)"
            Log "STAGE2 | Applying linear gain + preserving metadata: $($file.Name)"

            $filterArgs = "loudnorm=I=${lufsStr}:TP=${tpStr}:LRA=${lraStr}:measured_I=$($stats.input_i):measured_TP=$($stats.input_tp):measured_LRA=$($stats.input_lra):measured_thresh=$($stats.input_thresh):linear=true:print_format=json"

            $mapArgs = @("-map", "0:a")
            $idArgs  = @()
            if ($outputExt -ne ".wav") { $mapArgs += @("-map", "0:v?", "-c:v", "copy") }
            if ($outputExt -eq ".mp3") { $idArgs = @("-id3v2_version", "3", "-disposition:v:0", "attached_pic") }

            $pass2Args = @("-y", "-hide_banner", "-i", $file.FullName) + $mapArgs + @("-map_metadata", "0") + $idArgs + @("-af", $filterArgs) + $codecArgs + @($outputFile)
            $pass2Result = Invoke-FFmpegCapture -ArgList $pass2Args

            if ($pass2Result.LaunchError) {
                Log "ERROR | Could not launch FFmpeg for Pass 2: $($pass2Result.LaunchError)"
                $syncHash.ErrorCount++; $syncHash.ErrorFiles.Add($file.Name)
                continue
            }
            if ($pass2Result.ExitCode -ne 0) {
                Log "ERROR | $($file.Name): FFmpeg Pass 2 exited with code $($pass2Result.ExitCode). Detail: $(Get-ErrorSnippet $pass2Result.Output)"
                $syncHash.ErrorCount++; $syncHash.ErrorFiles.Add($file.Name)
                continue
            }

            $pass2Raw = $pass2Result.Output
            if ($pass2Raw -match '(?s)\{[^{}]*"normalization_type"[^{}]*\}') {
                try {
                    $stats2 = $Matches[0] | ConvertFrom-Json
                    if ($stats2.normalization_type -ne "linear") {
                        $maxSafeGain = [math]::Round(([double]$tpStr) - $originalTP, 2)
                        $suggestedLufs = [math]::Round($originalI + $maxSafeGain, 1)
                        Log "WARN | $($file.Name): reverted to DYNAMIC mode. Needed gain +$gainOffset dB, but max safe gain (peak-limited) is only $maxSafeGain dB (source peak $originalTP dBTP). To keep this file linear, target LUFS would need to be ~$suggestedLufs or lower - source is likely already hot/clipped."
                        $syncHash.WarnCount++; $syncHash.WarnFiles.Add($file.Name)
                    } else {
                        Log "OK | $($file.Name): linear normalization + metadata preserved ($originalI -> $lufsStr LUFS)."
                        $syncHash.OKCount++
                    }
                } catch {
                    Log "WARN | $($file.Name): normalization_type parse failed, but file + metadata were written."
                    $syncHash.WarnCount++; $syncHash.WarnFiles.Add($file.Name)
                }
            } else {
                Log "WARN | $($file.Name): could not confirm normalization_type, but file + metadata were written."
                $syncHash.WarnCount++; $syncHash.WarnFiles.Add($file.Name)
            }
        } else {
            Log "ERROR | $($file.Name): Could not parse measurement JSON. Exit code: $($pass1Result.ExitCode). Detail: $(Get-ErrorSnippet $pass1)"
            $syncHash.ErrorCount++; $syncHash.ErrorFiles.Add($file.Name)
        }
    }

    Log "DONE | Batch processing complete."
    $syncHash.Running = $false
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
$colBg      = [System.Drawing.Color]::FromArgb(24, 24, 27)
$colPanel   = [System.Drawing.Color]::FromArgb(36, 36, 40)
$colAccent  = [System.Drawing.Color]::FromArgb(0, 180, 216)
$colAccent2 = [System.Drawing.Color]::FromArgb(255, 159, 28)
$colText    = [System.Drawing.Color]::FromArgb(230, 230, 230)
$colSubtext = [System.Drawing.Color]::FromArgb(150, 150, 155)
$colGood    = [System.Drawing.Color]::FromArgb(120, 220, 140)
$colDebug   = [System.Drawing.Color]::FromArgb(100, 100, 110)
$colWarn    = [System.Drawing.Color]::FromArgb(255, 179, 71)
$colError   = [System.Drawing.Color]::FromArgb(255, 90, 90)
$colCoffee  = [System.Drawing.Color]::FromArgb(255, 221, 87)

$fontTitle = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$fontStep  = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$fontBase  = New-Object System.Drawing.Font("Segoe UI", 9)
$fontSmall = New-Object System.Drawing.Font("Segoe UI", 8)

$form = New-Object System.Windows.Forms.Form
$form.Text = "LUFsync"
$form.Size = New-Object System.Drawing.Size(680, 870)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = $colBg
$form.Font = $fontBase

$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.AutoPopDelay = 8000
$tooltip.InitialDelay = 300

function New-SectionPanel($y, $height) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point(15, $y)
    $p.Size = New-Object System.Drawing.Size(640, $height)
    $p.BackColor = $colPanel
    $form.Controls.Add($p)
    return $p
}
function New-StepLabel($panel, $text) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.ForeColor = $colAccent
    $lbl.Font = $fontStep
    $lbl.Location = New-Object System.Drawing.Point(15, 10)
    $lbl.AutoSize = $true
    $panel.Controls.Add($lbl)
}
function New-FieldLabel($panel, $text, $x, $y, $w = 150) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.ForeColor = $colText
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    $lbl.Size = New-Object System.Drawing.Size($w, 20)
    $panel.Controls.Add($lbl)
    return $lbl
}

# --- Header: title, credit, subtitle, Buy Me a Coffee ----------------------
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "LUFSYNC"
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $colAccent
$lblTitle.Location = New-Object System.Drawing.Point(15, 12)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblCredit = New-Object System.Windows.Forms.Label
$lblCredit.Text = "Created From Fotis Pastrakis"
$lblCredit.Font = $fontSmall
$lblCredit.ForeColor = $colSubtext
$lblCredit.Location = New-Object System.Drawing.Point(18, 44)
$lblCredit.AutoSize = $true
$form.Controls.Add($lblCredit)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = "Two-pass linear loudnorm  |  Genre presets  |  Preserves metadata & cover art"
$lblSubtitle.Font = $fontSmall
$lblSubtitle.ForeColor = $colSubtext
$lblSubtitle.Location = New-Object System.Drawing.Point(18, 60)
$lblSubtitle.AutoSize = $true
$form.Controls.Add($lblSubtitle)

$btnCoffee = New-Object System.Windows.Forms.Button
$btnCoffee.Text = "Buy Me a Coffee"
$btnCoffee.Location = New-Object System.Drawing.Point(500, 15)
$btnCoffee.Size = New-Object System.Drawing.Size(155, 32)
$btnCoffee.FlatStyle = "Flat"
$btnCoffee.BackColor = $colCoffee
$btnCoffee.ForeColor = [System.Drawing.Color]::Black
$btnCoffee.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnCoffee.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCoffee.Add_Click({
    Start-Process "https://buymeacoffee.com/fotispastrw"
})
$form.Controls.Add($btnCoffee)
$tooltip.SetToolTip($btnCoffee, "Enjoying LUFsync? Support future development.")

# --- STEP 1 ------------------------------------------------------------------
$panel1 = New-SectionPanel 95 105
New-StepLabel $panel1 "STEP 1 - Choose Folders"

New-FieldLabel $panel1 "Input:" 15 40 60
$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Location = New-Object System.Drawing.Point(80, 38)
$txtInput.Size = New-Object System.Drawing.Size(430, 22)
$txtInput.Text = "C:\Users\fotis\Music\RawSong"
$txtInput.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
$txtInput.ForeColor = $colText
$txtInput.BorderStyle = "FixedSingle"
$panel1.Controls.Add($txtInput)
$tooltip.SetToolTip($txtInput, "Folder containing your raw, unmastered tracks (mp3/wav/flac). Subfolders are included.")

$btnInput = New-Object System.Windows.Forms.Button
$btnInput.Text = "Browse..."
$btnInput.Location = New-Object System.Drawing.Point(520, 37)
$btnInput.Size = New-Object System.Drawing.Size(100, 24)
$btnInput.FlatStyle = "Flat"
$btnInput.BackColor = [System.Drawing.Color]::FromArgb(60,60,65)
$btnInput.ForeColor = $colText
$btnInput.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Select the folder containing raw tracks"
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtInput.Text = $fbd.SelectedPath }
})
$panel1.Controls.Add($btnInput)

New-FieldLabel $panel1 "Output:" 15 75 60
$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location = New-Object System.Drawing.Point(80, 73)
$txtOutput.Size = New-Object System.Drawing.Size(430, 22)
$txtOutput.Text = "C:\Users\fotis\Music\MasteredSong"
$txtOutput.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
$txtOutput.ForeColor = $colText
$txtOutput.BorderStyle = "FixedSingle"
$panel1.Controls.Add($txtOutput)
$tooltip.SetToolTip($txtOutput, "Folder where mastered, normalized tracks will be saved. Created automatically if missing.")

$btnOutput = New-Object System.Windows.Forms.Button
$btnOutput.Text = "Browse..."
$btnOutput.Location = New-Object System.Drawing.Point(520, 72)
$btnOutput.Size = New-Object System.Drawing.Size(100, 24)
$btnOutput.FlatStyle = "Flat"
$btnOutput.BackColor = [System.Drawing.Color]::FromArgb(60,60,65)
$btnOutput.ForeColor = $colText
$btnOutput.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Select the folder to save mastered tracks"
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtOutput.Text = $fbd.SelectedPath }
})
$panel1.Controls.Add($btnOutput)

# --- STEP 2 --------------------------------------------------------------------
$panel2 = New-SectionPanel 210 180
New-StepLabel $panel2 "STEP 2 - Pick a Genre Preset (applies instantly)"

$genreButtons = @{}
$bx = 15; $by = 40; $bw = 148; $bh = 32; $gap = 8
$i = 0
foreach ($name in $genrePresets.Keys) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $name
    $btn.Tag = $name
    $col = $i % 4
    $row = [math]::Floor($i / 4)
    $btn.Location = New-Object System.Drawing.Point(($bx + $col * ($bw + $gap)), ($by + $row * ($bh + $gap)))
    $btn.Size = New-Object System.Drawing.Size($bw, $bh)
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderColor = $colAccent
    $btn.FlatAppearance.BorderSize = 1
    $btn.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
    $btn.ForeColor = $colText
    $btn.Font = $fontSmall
    $panel2.Controls.Add($btn)
    $genreButtons[$name] = $btn
    $i++
}

$lblApplied = New-Object System.Windows.Forms.Label
$lblApplied.Text = "No preset applied yet - showing default values below."
$lblApplied.ForeColor = $colSubtext
$lblApplied.Font = $fontSmall
$lblApplied.Location = New-Object System.Drawing.Point(15, 148)
$lblApplied.Size = New-Object System.Drawing.Size(610, 20)
$panel2.Controls.Add($lblApplied)

# --- STEP 3 ---------------------------------------------------------------------
$panel3 = New-SectionPanel 400 130
New-StepLabel $panel3 "STEP 3 - Fine-Tune (optional - editing switches to Custom)"

New-FieldLabel $panel3 "Target LUFS:" 15 45 110
$numLUFS = New-Object System.Windows.Forms.NumericUpDown
$numLUFS.Location = New-Object System.Drawing.Point(130, 43)
$numLUFS.Size = New-Object System.Drawing.Size(80, 22)
$numLUFS.DecimalPlaces = 1
$numLUFS.Increment = 0.5
$numLUFS.Minimum = -24
$numLUFS.Maximum = -6
$numLUFS.Value = -10
$numLUFS.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
$numLUFS.ForeColor = $colText
$panel3.Controls.Add($numLUFS)
$tooltip.SetToolTip($numLUFS, "Integrated loudness target. Louder = more competitive on a club system, but less headroom. Typical club range: -12 to -7.")

New-FieldLabel $panel3 "True Peak (dBTP):" 230 45 130
$numTP = New-Object System.Windows.Forms.NumericUpDown
$numTP.Location = New-Object System.Drawing.Point(370, 43)
$numTP.Size = New-Object System.Drawing.Size(80, 22)
$numTP.DecimalPlaces = 1
$numTP.Increment = 0.1
$numTP.Minimum = -3
$numTP.Maximum = 0
$numTP.Value = -1.0
$numTP.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
$numTP.ForeColor = $colText
$panel3.Controls.Add($numTP)
$tooltip.SetToolTip($numTP, "Maximum true-peak ceiling to prevent clipping/distortion. -1.0 dBTP is a safe universal default.")

New-FieldLabel $panel3 "Loudness Range (LRA):" 15 85 150
$numLRA = New-Object System.Windows.Forms.NumericUpDown
$numLRA.Location = New-Object System.Drawing.Point(170, 83)
$numLRA.Size = New-Object System.Drawing.Size(80, 22)
$numLRA.Minimum = 1
$numLRA.Maximum = 20
$numLRA.Value = 11
$numLRA.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
$numLRA.ForeColor = $colText
$panel3.Controls.Add($numLRA)
$tooltip.SetToolTip($numLRA, "How much dynamic range is preserved. Higher = keeps quiet/loud contrast (good for bridges/breakdowns). Lower = more consistent loudness.")

$script:applyingPreset = $false
$flashTimer = New-Object System.Windows.Forms.Timer
$flashTimer.Interval = 350
$flashTimer.Add_Tick({
    $numLUFS.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
    $numTP.BackColor   = [System.Drawing.Color]::FromArgb(50,50,55)
    $numLRA.BackColor  = [System.Drawing.Color]::FromArgb(50,50,55)
    $flashTimer.Stop()
})

function Apply-GenrePreset($name) {
    $script:applyingPreset = $true
    $preset = $genrePresets[$name]
    $numLUFS.Value = [decimal]$preset[0]
    $numTP.Value   = [decimal]$preset[1]
    $numLRA.Value  = [decimal]$preset[2]
    $numLUFS.BackColor = $colAccent2
    $numTP.BackColor   = $colAccent2
    $numLRA.BackColor  = $colAccent2
    $flashTimer.Stop(); $flashTimer.Start()

    foreach ($b in $genreButtons.Values) {
        $b.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
        $b.FlatAppearance.BorderSize = 1
    }
    $genreButtons[$name].BackColor = $colAccent
    $genreButtons[$name].FlatAppearance.BorderSize = 2

    $lblApplied.Text = "Applied: $name  ->  LUFS $($preset[0])  |  TP $($preset[1])  |  LRA $($preset[2])"
    $lblApplied.ForeColor = $colGood
    $script:applyingPreset = $false
}

foreach ($name in $genreButtons.Keys) {
    $genreButtons[$name].Add_Click({ Apply-GenrePreset $this.Tag }.GetNewClosure())
}

$valueChangedHandler = {
    if (-not $script:applyingPreset) {
        foreach ($b in $genreButtons.Values) {
            $b.BackColor = [System.Drawing.Color]::FromArgb(50,50,55)
            $b.FlatAppearance.BorderSize = 1
        }
        $lblApplied.Text = "Custom values in use (no preset selected)."
        $lblApplied.ForeColor = $colSubtext
    }
}
$numLUFS.Add_ValueChanged($valueChangedHandler)
$numTP.Add_ValueChanged($valueChangedHandler)
$numLRA.Add_ValueChanged($valueChangedHandler)

# --- STEP 4 -----------------------------------------------------------------
$panel4 = New-SectionPanel 540 90
New-StepLabel $panel4 "STEP 4 - Output Format & Run"

$chkMp3 = New-Object System.Windows.Forms.CheckBox
$chkMp3.Text = "Force MP3 320k output (recommended for DJ decks)"
$chkMp3.Location = New-Object System.Drawing.Point(15, 40)
$chkMp3.Size = New-Object System.Drawing.Size(400, 22)
$chkMp3.Checked = $true
$chkMp3.ForeColor = $colText
$panel4.Controls.Add($chkMp3)
$tooltip.SetToolTip($chkMp3, "Checked: everything becomes 320k MP3 (best deck compatibility). Unchecked: WAV/FLAC sources stay lossless.")

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Start Processing"
$btnStart.Location = New-Object System.Drawing.Point(410, 35)
$btnStart.Size = New-Object System.Drawing.Size(130, 32)
$btnStart.FlatStyle = "Flat"
$btnStart.BackColor = $colAccent
$btnStart.ForeColor = [System.Drawing.Color]::Black
$btnStart.Font = $fontStep
$panel4.Controls.Add($btnStart)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancel"
$btnCancel.Location = New-Object System.Drawing.Point(545, 35)
$btnCancel.Size = New-Object System.Drawing.Size(80, 32)
$btnCancel.Enabled = $false
$btnCancel.FlatStyle = "Flat"
$btnCancel.BackColor = [System.Drawing.Color]::FromArgb(60,60,65)
$btnCancel.ForeColor = $colText
$panel4.Controls.Add($btnCancel)

# --- Progress + Log -----------------------------------------------------------
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 640)
$progressBar.Size = New-Object System.Drawing.Size(640, 18)
$form.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Idle - configure the steps above, then press Start."
$lblStatus.ForeColor = $colSubtext
$lblStatus.Location = New-Object System.Drawing.Point(15, 663)
$lblStatus.Size = New-Object System.Drawing.Size(640, 20)
$form.Controls.Add($lblStatus)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(15, 687)
$logBox.Size = New-Object System.Drawing.Size(640, 150)
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::Black
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BorderStyle = "FixedSingle"
$form.Controls.Add($logBox)

function Write-ColoredLog($text) {
    $color = [System.Drawing.Color]::White
    if ($text -match '^ERROR') { $color = [System.Drawing.Color]::Red }
    elseif ($text -match '^WARN')  { $color = [System.Drawing.Color]::Orange }
    elseif ($text -match '^OK')    { $color = $colGood }
    elseif ($text -match '^STAGE') { $color = $colAccent }
    elseif ($text -match '^DONE')  { $color = [System.Drawing.Color]::LimeGreen }
    elseif ($text -match '^DEBUG') { $color = $colDebug }
    else { $color = [System.Drawing.Color]::LightGray }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionColor = $color
    $logBox.AppendText("$text`r`n")
    $logBox.ScrollToCaret()
}

# --- Completion report modal (dark-themed, matches app style) --------------
function Show-ReportModal($okCount, $warnCount, $errorCount, $warnFiles, $errorFiles) {
    $total = $okCount + $warnCount + $errorCount

    $report = New-Object System.Windows.Forms.Form
    $report.Text = "LUFsync - Batch Report"
    $report.Size = New-Object System.Drawing.Size(480, 420)
    $report.StartPosition = "CenterParent"
    $report.FormBorderStyle = "FixedDialog"
    $report.MaximizeBox = $false
    $report.MinimizeBox = $false
    $report.BackColor = $colBg

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "BATCH COMPLETE"
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = $colAccent
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.AutoSize = $true
    $report.Controls.Add($lbl)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Text = "$total file(s) processed"
    $summary.ForeColor = $colSubtext
    $summary.Location = New-Object System.Drawing.Point(20, 45)
    $summary.AutoSize = $true
    $report.Controls.Add($summary)

    $stats = New-Object System.Windows.Forms.Label
    $stats.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $stats.Location = New-Object System.Drawing.Point(20, 75)
    $stats.Size = New-Object System.Drawing.Size(430, 60)
    $stats.Text = "Linear normalization OK:   $okCount`r`nDynamic fallback (WARN):  $warnCount`r`nFailed (ERROR):            $errorCount"
    $stats.ForeColor = $colText
    $report.Controls.Add($stats)

    $listLabel = New-Object System.Windows.Forms.Label
    $listLabel.Text = "Files needing attention:"
    $listLabel.ForeColor = $colText
    $listLabel.Location = New-Object System.Drawing.Point(20, 145)
    $listLabel.AutoSize = $true
    $report.Controls.Add($listLabel)

    $listBox = New-Object System.Windows.Forms.RichTextBox
    $listBox.Location = New-Object System.Drawing.Point(20, 170)
    $listBox.Size = New-Object System.Drawing.Size(430, 180)
    $listBox.ReadOnly = $true
    $listBox.BackColor = [System.Drawing.Color]::Black
    $listBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $report.Controls.Add($listBox)

    foreach ($f in $errorFiles) {
        $listBox.SelectionColor = $colError
        $listBox.AppendText("[ERROR] $f`r`n")
    }
    foreach ($f in $warnFiles) {
        $listBox.SelectionColor = $colWarn
        $listBox.AppendText("[WARN]  $f`r`n")
    }
    if ($warnFiles.Count -eq 0 -and $errorFiles.Count -eq 0) {
        $listBox.SelectionColor = $colGood
        $listBox.AppendText("All files normalized cleanly in linear mode. Nothing needs attention.`r`n")
    }

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Close"
    $btnOk.Location = New-Object System.Drawing.Point(370, 355)
    $btnOk.Size = New-Object System.Drawing.Size(80, 28)
    $btnOk.FlatStyle = "Flat"
    $btnOk.BackColor = $colAccent
    $btnOk.ForeColor = [System.Drawing.Color]::Black
    $btnOk.Add_Click({ $report.Close() })
    $report.Controls.Add($btnOk)

    $report.ShowDialog($form)
}

# --- Background runspace plumbing --------------------------------------------
$script:psInstance = $null
$script:handle = $null

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    while ($syncHash.Log.Count -gt 0) { Write-ColoredLog ($syncHash.Log.Dequeue()) }
    if ($syncHash.Total -gt 0) {
        $progressBar.Maximum = $syncHash.Total
        $progressBar.Value = [math]::Min($syncHash.Progress, $syncHash.Total)
        $lblStatus.Text = "Processing $($syncHash.Progress) / $($syncHash.Total)..."
    }
    if (-not $syncHash.Running -and $script:handle -ne $null -and $script:handle.IsCompleted) {
        $script:psInstance.EndInvoke($script:handle)
        $script:psInstance.Dispose()
        $script:psInstance = $null
        $script:handle = $null
        $timer.Stop()
        $btnStart.Enabled = $true
        $btnCancel.Enabled = $false
        $lblStatus.Text = "Finished."
        Show-ReportModal $syncHash.OKCount $syncHash.WarnCount $syncHash.ErrorCount $syncHash.WarnFiles $syncHash.ErrorFiles
    }
})

$btnStart.Add_Click({
    if (!(Test-Path $txtInput.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Input folder does not exist.", "Error") | Out-Null
        return
    }
    $logBox.Clear()
    $syncHash.Log.Clear()
    $syncHash.Progress = 0
    $syncHash.Total = 0
    $syncHash.Running = $true
    $syncHash.Cancel = $false
    $syncHash.OKCount = 0
    $syncHash.WarnCount = 0
    $syncHash.ErrorCount = 0
    $syncHash.WarnFiles.Clear()
    $syncHash.ErrorFiles.Clear()

    $btnStart.Enabled = $false
    $btnCancel.Enabled = $true
    $lblStatus.Text = "Starting..."

    $script:psInstance = [powershell]::Create()
    $script:psInstance.AddScript($workerScript).AddArgument($txtInput.Text).AddArgument($txtOutput.Text).AddArgument($numLUFS.Value).AddArgument($numTP.Value).AddArgument($numLRA.Value).AddArgument($chkMp3.Checked).AddArgument($syncHash) | Out-Null
    $script:handle = $script:psInstance.BeginInvoke()
    $timer.Start()
})

$btnCancel.Add_Click({
    $syncHash.Cancel = $true
    $lblStatus.Text = "Cancelling after current file..."
})

[System.Windows.Forms.Application]::Run($form)
