Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# LUFsync
# Two-pass FFmpeg loudnorm (linear=true) DJ mix batch normalizer.
#
# Created From Fotis Pastrakis
#
# v13: Removed the decorative step-nav tab row (redundant with the kicker/
# title already on each section). PayPal button now uses the same red
# accent fill as Start Processing instead of a blue outline. Window and
# log box enlarged so more of the batch's live processing output is
# visible without scrolling. Processing engine unchanged from v10.
# ---------------------------------------------------------------------------

$paypalUrl = "https://paypal.me/fotisps1"

$inv = [System.Globalization.CultureInfo]::InvariantCulture

$syncHash = [hashtable]::Synchronized(@{
    Log           = New-Object System.Collections.Generic.Queue[string]
    Progress      = 0
    Total         = 0
    Running       = $false
    Cancel        = $false
    OKCount       = 0
    WarnCount     = 0
    ErrorCount    = 0
    WarnFiles     = New-Object System.Collections.Generic.List[string]
    ErrorFiles    = New-Object System.Collections.Generic.List[string]
    AnalyzeOnly   = $false
    AnalysisRows  = New-Object System.Collections.Generic.List[string]
    AnalysisPath  = ""
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
    param($inputDir, $outputDir, $targetLUFS, $truePeak, $loudnessRange, $forceMp3, $analyzeOnly, $syncHash)

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

        if (-not ($pass1 -match '(?s)\{[^{}]*"input_i"[^{}]*\}')) {
            Log "ERROR | $($file.Name): Could not parse measurement JSON. Exit code: $($pass1Result.ExitCode). Detail: $(Get-ErrorSnippet $pass1)"
            $syncHash.ErrorCount++; $syncHash.ErrorFiles.Add($file.Name)
            continue
        }

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

        $originalI   = [double]$stats.input_i
        $originalTP  = [double]$stats.input_tp
        $originalLRA = [double]$stats.input_lra
        $crest       = [math]::Round($originalTP - $originalI, 2)

        if ($analyzeOnly) {
            Log "INFO | $($file.Name): I=$originalI LUFS  TP=$originalTP dBTP  LRA=$originalLRA LU  Crest=$crest dB"
            $syncHash.AnalysisRows.Add("$($file.Name)|$originalI|$originalTP|$originalLRA|$crest")
            continue
        }

        $maxSafeI = [math]::Round($originalI + (([double]$tpStr) - $originalTP), 2)
        $effectiveI = [math]::Min([double]$lufsStr, $maxSafeI)
        $effectiveLRA = [math]::Max([double]$lraStr, $originalLRA)

        $clampNotes = @()
        if ([math]::Round($effectiveI, 2) -ne [double]$lufsStr) {
            $clampNotes += "target LUFS clamped from $lufsStr to $($effectiveI.ToString('0.0', $inv)) (peak-limited)"
        }
        if ([math]::Round($effectiveLRA, 2) -ne [double]$lraStr) {
            $clampNotes += "LRA relaxed from $lraStr to $($effectiveLRA.ToString('0.0', $inv)) (source dynamics exceed preset)"
        }

        $gainOffset = [math]::Round($effectiveI - $originalI, 2)
        $direction  = if ($gainOffset -gt 0) { "BOOSTED" } else { "REDUCED" }
        Log "INFO | $($file.Name): $direction by $gainOffset dB (measured $originalI LUFS, peak $originalTP dBTP, LRA $originalLRA)"
        if ($clampNotes.Count -gt 0) { Log "INFO | $($file.Name): $($clampNotes -join '; ')" }
        Log "STAGE2 | Applying linear gain + preserving metadata: $($file.Name)"

        $effectiveIStr   = $effectiveI.ToString("0.0", $inv)
        $effectiveLRAStr = $effectiveLRA.ToString("0.0", $inv)

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
        $relativeDir = Split-Path -Path (Resolve-Path -Relative -Path $file.FullName -RelativeBasePath $inputDir) -Parent
        $destDir = Join-Path -Path $outputDir -ChildPath $relativeDir
        if (!(Test-Path -Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $outputFile = Join-Path -Path $destDir -ChildPath ($file.BaseName + $outputExt)

        $filterArgs = "loudnorm=I=${effectiveIStr}:TP=${tpStr}:LRA=${effectiveLRAStr}:measured_I=$($stats.input_i):measured_TP=$($stats.input_tp):measured_LRA=$($stats.input_lra):measured_thresh=$($stats.input_thresh):linear=true:print_format=json"

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
                    Log "WARN | $($file.Name): UNEXPECTED dynamic fallback despite clamping. Investigate (I=$originalI, TP=$originalTP, LRA=$originalLRA)."
                    $syncHash.WarnCount++; $syncHash.WarnFiles.Add($file.Name)
                } else {
                    Log "OK | $($file.Name): linear normalization + metadata preserved ($originalI -> $effectiveIStr LUFS)."
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
    }

    if ($analyzeOnly -and $syncHash.AnalysisRows.Count -gt 0) {
        $csvPath = Join-Path -Path $outputDir -ChildPath ("LUFsync_Analysis_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".csv")
        if (!(Test-Path -Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
        "FileName,MeasuredLUFS,MeasuredTP,MeasuredLRA,CrestFactor" | Out-File -FilePath $csvPath -Encoding utf8
        foreach ($row in $syncHash.AnalysisRows) {
            $parts = $row -split '\|'
            $escapedName = '"' + ($parts[0] -replace '"', '""') + '"'
            "$escapedName,$($parts[1]),$($parts[2]),$($parts[3]),$($parts[4])" | Out-File -FilePath $csvPath -Append -Encoding utf8
        }
        $syncHash.AnalysisPath = $csvPath
        Log "INFO | Analysis CSV saved: $csvPath"
    }

    Log "DONE | Batch processing complete."
    $syncHash.Running = $false
}

# ---------------------------------------------------------------------------
# UI - black/red editorial reskin (native WinForms + GDI+ only)
# ---------------------------------------------------------------------------
$colBg      = [System.Drawing.Color]::FromArgb(11, 11, 13)
$colField   = [System.Drawing.Color]::FromArgb(22, 22, 25)
$colAccent  = [System.Drawing.Color]::FromArgb(232, 56, 79)
$colText    = [System.Drawing.Color]::FromArgb(240, 240, 235)
$colSubtext = [System.Drawing.Color]::FromArgb(130, 130, 135)
$colDivider = [System.Drawing.Color]::FromArgb(40, 40, 44)
$colGood    = [System.Drawing.Color]::FromArgb(120, 220, 140)
$colWarn    = [System.Drawing.Color]::FromArgb(255, 179, 71)
$colError   = [System.Drawing.Color]::FromArgb(255, 90, 90)
$colDebug   = [System.Drawing.Color]::FromArgb(90, 90, 96)
$colAccent2 = [System.Drawing.Color]::FromArgb(255, 159, 28)

$fontHeadline = New-Object System.Drawing.Font("Arial Black", 26, [System.Drawing.FontStyle]::Bold)
$fontTitle    = New-Object System.Drawing.Font("Arial Black", 12, [System.Drawing.FontStyle]::Bold)
$fontKicker   = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$fontBase     = New-Object System.Drawing.Font("Segoe UI", 9)
$fontCaption  = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
$fontMono     = New-Object System.Drawing.Font("Consolas", 9)

$form = New-Object System.Windows.Forms.Form
$form.Text = "LUFsync"
$form.Size = New-Object System.Drawing.Size(700, 1150)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = $colBg
$form.Font = $fontBase

$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.AutoPopDelay = 8000
$tooltip.InitialDelay = 300

function Add-Divider($y, $width = 660, $x = 20) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($width, 1)
    $p.BackColor = $colDivider
    $form.Controls.Add($p)
}
function Add-Kicker($text, $y, $x = 20) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text.ToUpper()
    $lbl.Font = $fontKicker
    $lbl.ForeColor = $colAccent
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    $lbl.AutoSize = $true
    $form.Controls.Add($lbl)
    return $lbl
}
function Add-SectionTitle($text, $y, $x = 18) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text.ToUpper()
    $lbl.Font = $fontTitle
    $lbl.ForeColor = $colText
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    $lbl.AutoSize = $true
    $form.Controls.Add($lbl)
    return $lbl
}
function Add-Caption($text, $x, $y, $w = 200) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text.ToUpper()
    $lbl.Font = $fontCaption
    $lbl.ForeColor = $colSubtext
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    $lbl.Size = New-Object System.Drawing.Size($w, 16)
    $form.Controls.Add($lbl)
    return $lbl
}

$topBar = New-Object System.Windows.Forms.Panel
$topBar.Location = New-Object System.Drawing.Point(0, 0)
$topBar.Size = New-Object System.Drawing.Size(700, 46)
$topBar.BackColor = $colBg
$form.Controls.Add($topBar)
$topBar.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($colDivider, 1)
    $e.Graphics.DrawLine($pen, 0, 45, $s.Width, 45)
})

$lblBrand = New-Object System.Windows.Forms.Label
$lblBrand.Text = "FOTIS PASTRAKIS"
$lblBrand.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblBrand.ForeColor = $colText
$lblBrand.Location = New-Object System.Drawing.Point(20, 14)
$lblBrand.AutoSize = $true
$topBar.Controls.Add($lblBrand)

$lblBrandDot = New-Object System.Windows.Forms.Label
$lblBrandDot.Text = "  -"
$lblBrandDot.Font = $lblBrand.Font
$lblBrandDot.ForeColor = $colAccent
$lblBrandDot.Location = New-Object System.Drawing.Point(($lblBrand.Location.X + 128), 14)
$lblBrandDot.AutoSize = $true
$topBar.Controls.Add($lblBrandDot)

$lblMeta = New-Object System.Windows.Forms.Label
$lblMeta.Text = "TWO-PASS LOUDNORM  -  GENRE PRESETS"
$lblMeta.Font = $fontCaption
$lblMeta.ForeColor = $colSubtext
$lblMeta.Location = New-Object System.Drawing.Point(430, 16)
$lblMeta.Size = New-Object System.Drawing.Size(250, 16)
$lblMeta.TextAlign = "MiddleRight"
$topBar.Controls.Add($lblMeta)

Add-Kicker "Audio Mastering - DJ Mix Pipeline" 64 | Out-Null

$lblHeadline = New-Object System.Windows.Forms.Label
$lblHeadline.Text = "LUFSYNC"
$lblHeadline.Font = $fontHeadline
$lblHeadline.ForeColor = $colText
$lblHeadline.Location = New-Object System.Drawing.Point(17, 84)
$lblHeadline.AutoSize = $true
$form.Controls.Add($lblHeadline)

$lblDesc = New-Object System.Windows.Forms.Label
$lblDesc.Text = "Two-pass linear loudnorm for DJ mix libraries. Genre presets, metadata passthrough, and automatic peak-safe clamping - no dynamic compression, ever."
$lblDesc.Font = $fontBase
$lblDesc.ForeColor = $colSubtext
$lblDesc.Location = New-Object System.Drawing.Point(20, 136)
$lblDesc.Size = New-Object System.Drawing.Size(480, 40)
$form.Controls.Add($lblDesc)

$btnPaypal = New-Object System.Windows.Forms.Button
$btnPaypal.Text = "SUPPORT VIA PAYPAL"
$btnPaypal.Location = New-Object System.Drawing.Point(505, 138)
$btnPaypal.Size = New-Object System.Drawing.Size(175, 34)
$btnPaypal.FlatStyle = "Flat"
$btnPaypal.FlatAppearance.BorderColor = $colAccent
$btnPaypal.FlatAppearance.BorderSize = 0
$btnPaypal.BackColor = $colAccent
$btnPaypal.ForeColor = [System.Drawing.Color]::Black
$btnPaypal.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnPaypal.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnPaypal.Add_Click({ Start-Process $paypalUrl })
$form.Controls.Add($btnPaypal)
$tooltip.SetToolTip($btnPaypal, "Enjoying LUFsync? Support future development via PayPal.")

$y = 195
Add-Kicker "Step 1 of 4" $y | Out-Null
Add-SectionTitle "Choose Folders" ($y + 16) | Out-Null
Add-Divider ($y + 52) 660 20

Add-Caption "Input Folder" 20 ($y + 64)
$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Location = New-Object System.Drawing.Point(20, ($y + 82))
$txtInput.Size = New-Object System.Drawing.Size(535, 24)
$txtInput.Text = "C:\Users\fotis\Music\RawSong"
$txtInput.BackColor = $colField
$txtInput.ForeColor = $colText
$txtInput.BorderStyle = "FixedSingle"
$form.Controls.Add($txtInput)
$tooltip.SetToolTip($txtInput, "Folder containing your raw, unmastered tracks (mp3/wav/flac). Subfolders are included.")

$btnInput = New-Object System.Windows.Forms.Button
$btnInput.Text = "BROWSE"
$btnInput.Location = New-Object System.Drawing.Point(565, ($y + 81))
$btnInput.Size = New-Object System.Drawing.Size(95, 26)
$btnInput.FlatStyle = "Flat"
$btnInput.FlatAppearance.BorderColor = $colDivider
$btnInput.BackColor = $colField
$btnInput.ForeColor = $colText
$btnInput.Font = $fontCaption
$btnInput.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Select the folder containing raw tracks"
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtInput.Text = $fbd.SelectedPath }
})
$form.Controls.Add($btnInput)

Add-Caption "Output Folder" 20 ($y + 116)
$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location = New-Object System.Drawing.Point(20, ($y + 134))
$txtOutput.Size = New-Object System.Drawing.Size(535, 24)
$txtOutput.Text = "C:\Users\fotis\Music\MasteredSong"
$txtOutput.BackColor = $colField
$txtOutput.ForeColor = $colText
$txtOutput.BorderStyle = "FixedSingle"
$form.Controls.Add($txtOutput)
$tooltip.SetToolTip($txtOutput, "Folder where mastered tracks / analysis CSV will be saved. Created automatically if missing.")

$btnOutput = New-Object System.Windows.Forms.Button
$btnOutput.Text = "BROWSE"
$btnOutput.Location = New-Object System.Drawing.Point(565, ($y + 133))
$btnOutput.Size = New-Object System.Drawing.Size(95, 26)
$btnOutput.FlatStyle = "Flat"
$btnOutput.FlatAppearance.BorderColor = $colDivider
$btnOutput.BackColor = $colField
$btnOutput.ForeColor = $colText
$btnOutput.Font = $fontCaption
$btnOutput.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Select the folder to save mastered tracks / analysis CSV"
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtOutput.Text = $fbd.SelectedPath }
})
$form.Controls.Add($btnOutput)

$y = 370
Add-Kicker "Step 2 of 4" $y | Out-Null
Add-SectionTitle "Genre Preset" ($y + 16) | Out-Null
Add-Divider ($y + 52) 660 20

$genreButtons = @{}
$bx = 20; $by = ($y + 64); $bw = 155; $bh = 34; $gap = 8
$i = 0
foreach ($name in $genrePresets.Keys) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $name.ToUpper()
    $btn.Tag = $name
    $col = $i % 4
    $row = [math]::Floor($i / 4)
    $btn.Location = New-Object System.Drawing.Point(($bx + $col * ($bw + $gap)), ($by + $row * ($bh + $gap)))
    $btn.Size = New-Object System.Drawing.Size($bw, $bh)
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderColor = $colDivider
    $btn.FlatAppearance.BorderSize = 1
    $btn.BackColor = $colField
    $btn.ForeColor = $colText
    $btn.Font = $fontCaption
    $form.Controls.Add($btn)
    $genreButtons[$name] = $btn
    $i++
}

$lblApplied = New-Object System.Windows.Forms.Label
$lblApplied.Text = "NO PRESET APPLIED YET - SHOWING DEFAULT VALUES BELOW"
$lblApplied.ForeColor = $colSubtext
$lblApplied.Font = $fontCaption
$lblApplied.Location = New-Object System.Drawing.Point(20, ($by + 2 * ($bh + $gap) + 4))
$lblApplied.Size = New-Object System.Drawing.Size(620, 18)
$form.Controls.Add($lblApplied)

$y = 580
Add-Kicker "Step 3 of 4" $y | Out-Null
Add-SectionTitle "Fine-Tune" ($y + 16) | Out-Null
Add-Divider ($y + 52) 660 20

Add-Caption "Target LUFS" 20 ($y + 64)
$numLUFS = New-Object System.Windows.Forms.NumericUpDown
$numLUFS.Location = New-Object System.Drawing.Point(20, ($y + 82))
$numLUFS.Size = New-Object System.Drawing.Size(90, 24)
$numLUFS.DecimalPlaces = 1
$numLUFS.Increment = 0.5
$numLUFS.Minimum = -24
$numLUFS.Maximum = -6
$numLUFS.Value = -10
$numLUFS.BackColor = $colField
$numLUFS.ForeColor = $colText
$form.Controls.Add($numLUFS)
$tooltip.SetToolTip($numLUFS, "Integrated loudness target. LUFsync clamps this per-file automatically if the source's true peak can't support it linearly.")

Add-Caption "True Peak (dBTP)" 235 ($y + 64) 150
$numTP = New-Object System.Windows.Forms.NumericUpDown
$numTP.Location = New-Object System.Drawing.Point(235, ($y + 82))
$numTP.Size = New-Object System.Drawing.Size(90, 24)
$numTP.DecimalPlaces = 1
$numTP.Increment = 0.1
$numTP.Minimum = -3
$numTP.Maximum = 0
$numTP.Value = -1.0
$numTP.BackColor = $colField
$numTP.ForeColor = $colText
$form.Controls.Add($numTP)
$tooltip.SetToolTip($numTP, "Maximum true-peak ceiling to prevent clipping/distortion. -1.0 dBTP is a safe universal default.")

Add-Caption "Loudness Range (LRA)" 450 ($y + 64) 180
$numLRA = New-Object System.Windows.Forms.NumericUpDown
$numLRA.Location = New-Object System.Drawing.Point(450, ($y + 82))
$numLRA.Size = New-Object System.Drawing.Size(90, 24)
$numLRA.Minimum = 1
$numLRA.Maximum = 20
$numLRA.Value = 11
$numLRA.BackColor = $colField
$numLRA.ForeColor = $colText
$form.Controls.Add($numLRA)
$tooltip.SetToolTip($numLRA, "LRA is scale-invariant: if a track's natural dynamic range exceeds this, LUFsync relaxes the target automatically rather than compress.")

$script:applyingPreset = $false
$flashTimer = New-Object System.Windows.Forms.Timer
$flashTimer.Interval = 350
$flashTimer.Add_Tick({
    $numLUFS.BackColor = $colField
    $numTP.BackColor   = $colField
    $numLRA.BackColor  = $colField
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
        $b.BackColor = $colField
        $b.ForeColor = $colText
        $b.FlatAppearance.BorderColor = $colDivider
    }
    $genreButtons[$name].BackColor = $colAccent
    $genreButtons[$name].ForeColor = [System.Drawing.Color]::Black
    $genreButtons[$name].FlatAppearance.BorderColor = $colAccent

    $lblApplied.Text = "APPLIED: $($name.ToUpper())  ->  LUFS $($preset[0])  |  TP $($preset[1])  |  LRA $($preset[2])"
    $lblApplied.ForeColor = $colGood
    $script:applyingPreset = $false
}

foreach ($name in $genreButtons.Keys) {
    $genreButtons[$name].Add_Click({ Apply-GenrePreset $this.Tag }.GetNewClosure())
}

$valueChangedHandler = {
    if (-not $script:applyingPreset) {
        foreach ($b in $genreButtons.Values) {
            $b.BackColor = $colField
            $b.ForeColor = $colText
            $b.FlatAppearance.BorderColor = $colDivider
        }
        $lblApplied.Text = "CUSTOM VALUES IN USE (NO PRESET SELECTED)"
        $lblApplied.ForeColor = $colSubtext
    }
}
$numLUFS.Add_ValueChanged($valueChangedHandler)
$numTP.Add_ValueChanged($valueChangedHandler)
$numLRA.Add_ValueChanged($valueChangedHandler)

$y = 715
Add-Kicker "Step 4 of 4" $y | Out-Null
Add-SectionTitle "Run" ($y + 16) | Out-Null
Add-Divider ($y + 52) 660 20

$chkAnalyze = New-Object System.Windows.Forms.CheckBox
$chkAnalyze.Text = "ANALYZE ONLY (MEASURE + EXPORT CSV, NO FILES WRITTEN)"
$chkAnalyze.Location = New-Object System.Drawing.Point(20, ($y + 64))
$chkAnalyze.Size = New-Object System.Drawing.Size(430, 22)
$chkAnalyze.Checked = $false
$chkAnalyze.ForeColor = $colText
$chkAnalyze.Font = $fontCaption
$form.Controls.Add($chkAnalyze)
$tooltip.SetToolTip($chkAnalyze, "Runs Pass 1 measurement across the whole folder and exports a CSV of each file's I/TP/LRA/crest factor.")

$chkMp3 = New-Object System.Windows.Forms.CheckBox
$chkMp3.Text = "FORCE MP3 320K OUTPUT (RECOMMENDED FOR DJ DECKS)"
$chkMp3.Location = New-Object System.Drawing.Point(20, ($y + 90))
$chkMp3.Size = New-Object System.Drawing.Size(400, 22)
$chkMp3.Checked = $true
$chkMp3.ForeColor = $colText
$chkMp3.Font = $fontCaption
$form.Controls.Add($chkMp3)
$tooltip.SetToolTip($chkMp3, "Checked: everything becomes 320k MP3 (best deck compatibility). Unchecked: WAV/FLAC sources stay lossless.")

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "START PROCESSING"
$btnStart.Location = New-Object System.Drawing.Point(455, ($y + 62))
$btnStart.Size = New-Object System.Drawing.Size(143, 35)
$btnStart.FlatStyle = "Flat"
$btnStart.BackColor = $colAccent
$btnStart.ForeColor = [System.Drawing.Color]::Black
$btnStart.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnStart)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "CANCEL"
$btnCancel.Location = New-Object System.Drawing.Point(605, ($y + 63))
$btnCancel.Size = New-Object System.Drawing.Size(75, 33)
$btnCancel.Enabled = $false
$btnCancel.FlatStyle = "Flat"
$btnCancel.FlatAppearance.BorderColor = $colDivider
$btnCancel.BackColor = $colField
$btnCancel.ForeColor = $colText
$btnCancel.Font = $fontCaption
$form.Controls.Add($btnCancel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, ($y + 110))
$progressBar.Size = New-Object System.Drawing.Size(660, 16)
$form.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "IDLE - CONFIGURE THE STEPS ABOVE, THEN PRESS START"
$lblStatus.ForeColor = $colSubtext
$lblStatus.Font = $fontCaption
$lblStatus.Location = New-Object System.Drawing.Point(20, ($y + 132))
$lblStatus.Size = New-Object System.Drawing.Size(660, 18)
$form.Controls.Add($lblStatus)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(20, ($y + 154))
$logBox.Size = New-Object System.Drawing.Size(660, 260)
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::Black
$logBox.ForeColor = $colText
$logBox.Font = $fontMono
$logBox.BorderStyle = "FixedSingle"
$form.Controls.Add($logBox)

function Write-ColoredLog($text) {
    $color = [System.Drawing.Color]::White
    if ($text -match '^ERROR') { $color = $colError }
    elseif ($text -match '^WARN')  { $color = $colWarn }
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
    $lbl.Font = $fontTitle
    $lbl.ForeColor = $colAccent
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.AutoSize = $true
    $report.Controls.Add($lbl)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Text = "$total FILE(S) PROCESSED"
    $summary.ForeColor = $colSubtext
    $summary.Font = $fontCaption
    $summary.Location = New-Object System.Drawing.Point(20, 48)
    $summary.AutoSize = $true
    $report.Controls.Add($summary)

    $stats = New-Object System.Windows.Forms.Label
    $stats.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $stats.Location = New-Object System.Drawing.Point(20, 75)
    $stats.Size = New-Object System.Drawing.Size(430, 60)
    $stats.Text = "Linear normalization OK:   $okCount`r`nUnexpected fallback (WARN): $warnCount`r`nFailed (ERROR):            $errorCount"
    $stats.ForeColor = $colText
    $report.Controls.Add($stats)

    $listLabel = New-Object System.Windows.Forms.Label
    $listLabel.Text = "FILES NEEDING ATTENTION"
    $listLabel.ForeColor = $colSubtext
    $listLabel.Font = $fontCaption
    $listLabel.Location = New-Object System.Drawing.Point(20, 145)
    $listLabel.AutoSize = $true
    $report.Controls.Add($listLabel)

    $listBox = New-Object System.Windows.Forms.RichTextBox
    $listBox.Location = New-Object System.Drawing.Point(20, 170)
    $listBox.Size = New-Object System.Drawing.Size(430, 180)
    $listBox.ReadOnly = $true
    $listBox.BackColor = [System.Drawing.Color]::Black
    $listBox.Font = $fontMono
    $report.Controls.Add($listBox)

    foreach ($f in $errorFiles) { $listBox.SelectionColor = $colError; $listBox.AppendText("[ERROR] $f`r`n") }
    foreach ($f in $warnFiles)  { $listBox.SelectionColor = $colWarn;  $listBox.AppendText("[WARN]  $f`r`n") }
    if ($warnFiles.Count -eq 0 -and $errorFiles.Count -eq 0) {
        $listBox.SelectionColor = $colGood
        $listBox.AppendText("All files normalized cleanly in linear mode. Nothing needs attention.`r`n")
    }

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "CLOSE"
    $btnOk.Location = New-Object System.Drawing.Point(370, 355)
    $btnOk.Size = New-Object System.Drawing.Size(80, 28)
    $btnOk.FlatStyle = "Flat"
    $btnOk.BackColor = $colAccent
    $btnOk.ForeColor = [System.Drawing.Color]::Black
    $btnOk.Font = $fontCaption
    $btnOk.Add_Click({ $report.Close() })
    $report.Controls.Add($btnOk)

    $report.ShowDialog($form)
}

function Show-AnalysisModal($rows, $csvPath) {
    $report = New-Object System.Windows.Forms.Form
    $report.Text = "LUFsync - Library Analysis"
    $report.Size = New-Object System.Drawing.Size(480, 420)
    $report.StartPosition = "CenterParent"
    $report.FormBorderStyle = "FixedDialog"
    $report.MaximizeBox = $false
    $report.MinimizeBox = $false
    $report.BackColor = $colBg

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "ANALYSIS COMPLETE"
    $lbl.Font = $fontTitle
    $lbl.ForeColor = $colAccent
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.AutoSize = $true
    $report.Controls.Add($lbl)

    $iVals = @(); $tpVals = @(); $lraVals = @(); $crestVals = @()
    foreach ($row in $rows) {
        $p = $row -split '\|'
        $iVals += [double]$p[1]; $tpVals += [double]$p[2]; $lraVals += [double]$p[3]; $crestVals += [double]$p[4]
    }

    $summary = New-Object System.Windows.Forms.Label
    $summary.Text = "$($rows.Count) file(s) analyzed. CSV saved to:`r`n$csvPath"
    $summary.ForeColor = $colSubtext
    $summary.Location = New-Object System.Drawing.Point(20, 48)
    $summary.Size = New-Object System.Drawing.Size(430, 40)
    $report.Controls.Add($summary)

    $statsText = ""
    if ($iVals.Count -gt 0) {
        $statsText = ("LUFS:  min {0:N1}  max {1:N1}  avg {2:N1}`r`n" -f ($iVals | Measure-Object -Minimum).Minimum, ($iVals | Measure-Object -Maximum).Maximum, ($iVals | Measure-Object -Average).Average) +
                     ("TP:    min {0:N1}  max {1:N1}  avg {2:N1}`r`n" -f ($tpVals | Measure-Object -Minimum).Minimum, ($tpVals | Measure-Object -Maximum).Maximum, ($tpVals | Measure-Object -Average).Average) +
                     ("LRA:   min {0:N1}  max {1:N1}  avg {2:N1}`r`n" -f ($lraVals | Measure-Object -Minimum).Minimum, ($lraVals | Measure-Object -Maximum).Maximum, ($lraVals | Measure-Object -Average).Average) +
                     ("Crest: min {0:N1}  max {1:N1}  avg {2:N1}" -f ($crestVals | Measure-Object -Minimum).Minimum, ($crestVals | Measure-Object -Maximum).Maximum, ($crestVals | Measure-Object -Average).Average)
    }
    $stats = New-Object System.Windows.Forms.Label
    $stats.Font = $fontMono
    $stats.Location = New-Object System.Drawing.Point(20, 95)
    $stats.Size = New-Object System.Drawing.Size(430, 80)
    $stats.Text = $statsText
    $stats.ForeColor = $colText
    $report.Controls.Add($stats)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Use these numbers to sanity-check your genre preset LRA/TP against what this folder actually contains."
    $hint.ForeColor = $colSubtext
    $hint.Font = $fontCaption
    $hint.Location = New-Object System.Drawing.Point(20, 178)
    $hint.Size = New-Object System.Drawing.Size(430, 30)
    $report.Controls.Add($hint)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "CLOSE"
    $btnOk.Location = New-Object System.Drawing.Point(370, 355)
    $btnOk.Size = New-Object System.Drawing.Size(80, 28)
    $btnOk.FlatStyle = "Flat"
    $btnOk.BackColor = $colAccent
    $btnOk.ForeColor = [System.Drawing.Color]::Black
    $btnOk.Font = $fontCaption
    $btnOk.Add_Click({ $report.Close() })
    $report.Controls.Add($btnOk)

    $report.ShowDialog($form)
}

$script:psInstance = $null
$script:handle = $null

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    while ($syncHash.Log.Count -gt 0) { Write-ColoredLog ($syncHash.Log.Dequeue()) }
    if ($syncHash.Total -gt 0) {
        $progressBar.Maximum = $syncHash.Total
        $progressBar.Value = [math]::Min($syncHash.Progress, $syncHash.Total)
        $lblStatus.Text = "PROCESSING $($syncHash.Progress) / $($syncHash.Total)..."
    }
    if (-not $syncHash.Running -and $script:handle -ne $null -and $script:handle.IsCompleted) {
        $script:psInstance.EndInvoke($script:handle)
        $script:psInstance.Dispose()
        $script:psInstance = $null
        $script:handle = $null
        $timer.Stop()
        $btnStart.Enabled = $true
        $btnCancel.Enabled = $false
        $lblStatus.Text = "FINISHED"

        if ($syncHash.AnalyzeOnly) {
            Show-AnalysisModal $syncHash.AnalysisRows $syncHash.AnalysisPath
        } else {
            Show-ReportModal $syncHash.OKCount $syncHash.WarnCount $syncHash.ErrorCount $syncHash.WarnFiles $syncHash.ErrorFiles
        }
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
    $syncHash.AnalyzeOnly = $chkAnalyze.Checked
    $syncHash.AnalysisRows.Clear()
    $syncHash.AnalysisPath = ""

    $btnStart.Enabled = $false
    $btnCancel.Enabled = $true
    $lblStatus.Text = if ($chkAnalyze.Checked) { "ANALYZING..." } else { "STARTING..." }

    $script:psInstance = [powershell]::Create()
    $script:psInstance.AddScript($workerScript).AddArgument($txtInput.Text).AddArgument($txtOutput.Text).AddArgument($numLUFS.Value).AddArgument($numTP.Value).AddArgument($numLRA.Value).AddArgument($chkMp3.Checked).AddArgument($chkAnalyze.Checked).AddArgument($syncHash) | Out-Null
    $script:handle = $script:psInstance.BeginInvoke()
    $timer.Start()
})

$btnCancel.Add_Click({
    $syncHash.Cancel = $true
    $lblStatus.Text = "CANCELLING AFTER CURRENT FILE..."
})

[System.Windows.Forms.Application]::Run($form)
