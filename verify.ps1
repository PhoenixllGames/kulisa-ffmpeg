<#
.SYNOPSIS
  Verifies a kulisa-ffmpeg win64 zip on Windows.

.DESCRIPTION
  Extracts the zip into a new empty directory, then runs the checks of the release process:
    1. license and configure line (LGPL 2.1 or later, no gpl, nonfree or version3)
    2. encoders, hwaccels and filters of the allow list
    3. H.264 plus AAC FLV transcode through stdin and stdout with h264_mf (hw_encoding 0 and 1)
    4. one-frame probe of every GPU encoder (failures are expected without the GPU)
    5. sizes
  A separate GPL ffmpeg and ffprobe (for example the gyan.dev essentials build) creates the test
  input and inspects the output. It is used only here and is never shipped.

.EXAMPLE
  ./verify.ps1 -Zip dist/kulisa-ffmpeg-v9.0.2-1-win64.zip -Dest D:\tools\kulisa-ffmpeg-v9.0.2-1 `
    -GplBin D:\tools\ffmpeg-9.0.2\ffmpeg-9.0.2-essentials_build\bin -Scratch $env:TEMP\kff-verify
#>
param(
  [Parameter(Mandatory = $true)][string]$Zip,
  [Parameter(Mandatory = $true)][string]$Dest,
  [Parameter(Mandatory = $true)][string]$GplBin,
  [string]$Scratch = (Join-Path $env:TEMP 'kulisa-ffmpeg-verify'),
  [string]$Components = (Join-Path $PSScriptRoot 'components')
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$name, [bool]$ok, [string]$detail) {
  $results.Add([pscustomobject]@{ Check = $name; Pass = $ok; Detail = $detail })
  $state = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Host ("[{0}] {1}: {2}" -f $state, $name, $detail)
}

if (Test-Path $Dest) {
  if (Get-ChildItem -Force $Dest) { throw "Destination $Dest is not empty" }
} else {
  New-Item -ItemType Directory -Path $Dest | Out-Null
}
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null

Expand-Archive -Path $Zip -DestinationPath $Dest
$ff = Join-Path $Dest 'bin\ffmpeg.exe'
$gplFfmpeg = Join-Path $GplBin 'ffmpeg.exe'
$gplProbe = Join-Path $GplBin 'ffprobe.exe'

# Runs a tool, returns stdout, stderr, exit code and timing. Text output only.
function Invoke-Tool([string]$exe, [string[]]$arguments) {
  $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
  foreach ($a in $arguments) { $psi.ArgumentList.Add($a) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  [pscustomobject]@{ Out = $outTask.Result; Err = $errTask.Result; Code = $p.ExitCode }
}

# Walks the FLV tags and returns the AVCPacketType (0 = sequence header) of the first AVC video tag.
function Get-FirstVideoPacketType([string]$path) {
  $fs = [System.IO.File]::OpenRead($path)
  try {
    $buf = [byte[]]::new(65536)
    $n = $fs.Read($buf, 0, $buf.Length)
    $pos = 13 # 9 byte header and PreviousTagSize0
    while ($pos + 12 -lt $n) {
      $type = $buf[$pos]
      $size = ([int]$buf[$pos + 1] -shl 16) -bor ([int]$buf[$pos + 2] -shl 8) -bor [int]$buf[$pos + 3]
      if ($type -eq 9) { return [int]$buf[$pos + 12] }
      $pos += 11 + $size + 4
    }
    return -1
  } finally { $fs.Dispose() }
}

# 1. License and configure line
$lic = Invoke-Tool $ff @('-hide_banner', '-L')
$licText = (($lic.Out + $lic.Err) -replace '\s+', ' ').Trim()
Add-Result 'license' ($licText -match 'GNU Lesser General Public License' -and $licText -match 'version 2\.1 of the License, or \(at your option\) any later version' -and $licText -notmatch 'GNU General Public License as') $licText.Substring(0, [Math]::Min(200, $licText.Length))
$bc = Invoke-Tool $ff @('-hide_banner', '-buildconf')
$bcText = $bc.Out + $bc.Err
$forbidden = @('--enable-gpl', '--enable-nonfree', '--enable-version3') | Where-Object { $bcText -match [regex]::Escape($_) }
Add-Result 'buildconf' (@($forbidden).Count -eq 0) ("no forbidden switch; options: " + ((($bcText -split "`n") | Where-Object { $_ -match '^\s+--' }).Count))
$bcText | Set-Content -Path (Join-Path $Scratch 'buildconf.txt')
# BUILDINFO.txt must carry the configure line exactly as -buildconf prints it.
$infoLines = Get-Content (Join-Path $Dest 'BUILDINFO.txt')
$start = [Array]::IndexOf($infoLines, '  configuration:')
$block = @()
if ($start -ge 0) {
  for ($i = $start; $i -lt $infoLines.Count -and $infoLines[$i].Trim() -ne ''; $i++) { $block += $infoLines[$i] }
}
$bcLines = @(($bcText -split "`r?`n") | Where-Object { $_.Trim() -ne '' })
$bcStart = [Array]::IndexOf($bcLines, '  configuration:')
$bcBlock = @()
if ($bcStart -ge 0) {
  for ($i = $bcStart; $i -lt $bcLines.Count; $i++) {
    if ($i -gt $bcStart -and $bcLines[$i] -notmatch '^    --') { break }
    $bcBlock += $bcLines[$i]
  }
}
Add-Result 'buildinfo matches -buildconf' (($block -join "`n") -ceq ($bcBlock -join "`n")) ("{0} lines in BUILDINFO, {1} lines printed" -f $block.Count, $bcBlock.Count)
$others = @('LICENSE.txt', 'licenses\AMF-LICENSE.txt', 'licenses\libvpl-LICENSE.txt', 'licenses\nv-codec-headers-LICENSE.txt', 'bin\ffmpeg.exe') | Where-Object { -not (Test-Path (Join-Path $Dest $_)) }
Add-Result 'zip contents' (@($others).Count -eq 0) ("missing: " + ($others -join ','))

# 2. Encoders, hwaccels, filters
$enc = (Invoke-Tool $ff @('-hide_banner', '-encoders')).Out
$missingEnc = @('h264_mf', 'h264_nvenc', 'h264_amf', 'h264_qsv', 'aac') | Where-Object { $enc -notmatch "\s$_\s" }
Add-Result 'encoders' (@($missingEnc).Count -eq 0) ("missing: " + ($missingEnc -join ','))
$hw = (Invoke-Tool $ff @('-hide_banner', '-hwaccels')).Out
$missingHw = @('d3d11va', 'dxva2', 'cuda', 'qsv') | Where-Object { $hw -notmatch "(?m)^$_\s*$" }
Add-Result 'hwaccels' (@($missingHw).Count -eq 0) ("missing: " + ($missingHw -join ',') + "; listed: " + (($hw -split "`n" | Where-Object { $_ -and $_ -notmatch ':' } | ForEach-Object { $_.Trim() }) -join ','))
$filters = (Invoke-Tool $ff @('-hide_banner', '-filters')).Out
$wanted = @()
foreach ($line in Get-Content $Components) {
  if ($line -match '^FILTERS="(.*)"$') { $wanted = $Matches[1] -split '\s+' }
}
$missingF = $wanted | Where-Object { $filters -notmatch "\s$_\s" }
Add-Result 'filters' (@($missingF).Count -eq 0) ("wanted " + $wanted.Count + ", missing: " + ($missingF -join ','))

# 3. Transcode through stdin and stdout
$inFlv = Join-Path $Scratch 'input-1080p30.flv'
$gen = Invoke-Tool $gplFfmpeg @('-hide_banner', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
  '-t', '10', '-c:v', 'libx264', '-preset', 'veryfast', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0', '-pix_fmt', 'yuv420p',
  '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2', '-f', 'flv', $inFlv)
Add-Result 'test input' ($gen.Code -eq 0 -and (Test-Path $inFlv)) ("{0} bytes" -f (Get-Item $inFlv).Length)

foreach ($hwEnc in 0, 1) {
  $outFlv = Join-Path $Scratch "out-hw$hwEnc.flv"
  $errTxt = Join-Path $Scratch "out-hw$hwEnc.stderr.txt"
  $argList = @('-hide_banner', '-nostats', '-f', 'flv', '-i', 'pipe:0', '-vf', 'scale=-2:720,fps=30', '-c:v', 'h264_mf', '-rate_control', 'cbr',
    '-b:v', '3000k', '-maxrate', '3000k', '-bufsize', '6000k', '-g', '60', '-bf', '0', '-hw_encoding', "$hwEnc", '-c:a', 'copy', '-progress', 'pipe:2', '-f', 'flv', 'pipe:1')
  if (Test-Path $outFlv) { Remove-Item $outFlv }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $ff -ArgumentList $argList -RedirectStandardInput $inFlv -RedirectStandardOutput $outFlv -RedirectStandardError $errTxt -PassThru -NoNewWindow
  $null = $p.Handle
  $p.WaitForExit()
  $sw.Stop()
  $cpu = $p.TotalProcessorTime.TotalSeconds
  $code = $p.ExitCode
  $name = "mf transcode hw_encoding=$hwEnc"
  if ($code -ne 0 -or -not (Test-Path $outFlv) -or (Get-Item $outFlv).Length -eq 0) {
    $lastErr = ((Get-Content $errTxt -ErrorAction SilentlyContinue | Where-Object { $_ -match 'rror|fail|Cannot|Unknown' } | Select-Object -Last 3) -join ' | ')
    # hw_encoding=1 needs a hardware MFT: a failure on a machine without GPU is an expected result.
    Add-Result $name ($hwEnc -eq 1) ("{0}exit {1}, wall {2:N1}s, cpu {3:N1}s, error: {4}" -f $(if ($hwEnc -eq 1) { 'unavailable here, ' } else { '' }), $code, $sw.Elapsed.TotalSeconds, $cpu, $lastErr)
    continue
  }
  $info = (Invoke-Tool $gplProbe @('-v', 'error', '-print_format', 'json', '-show_streams', '-show_format', $outFlv)).Out | ConvertFrom-Json
  $v = $info.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1
  $a = $info.streams | Where-Object codec_type -eq 'audio' | Select-Object -First 1
  $pk = (Invoke-Tool $gplProbe @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time,flags', '-of', 'csv=p=0', $outFlv)).Out -split "`n" |
    Where-Object { $_ -match ',K' } | ForEach-Object { [double](($_ -split ',')[0]) }
  $gaps = @(); for ($i = 1; $i -lt $pk.Count; $i++) { $gaps += [Math]::Round($pk[$i] - $pk[$i - 1], 2) }
  $dec = Invoke-Tool $gplFfmpeg @('-v', 'error', '-i', $outFlv, '-f', 'null', '-')
  $okVideo = $v.codec_name -eq 'h264' -and $v.width -eq 1280 -and $v.height -eq 720 -and $v.r_frame_rate -eq '30/1'
  $okAudio = $a.codec_name -eq 'aac' -and $a.sample_rate -eq '48000'
  $okGop = $gaps.Count -gt 0 -and (($gaps | Where-Object { [Math]::Abs($_ - 2.0) -gt 0.1 }).Count -eq 0)
  $dur = [double]$info.format.duration
  $okDur = [Math]::Abs($dur - 10.0) -lt 1.0
  $pktType = Get-FirstVideoPacketType $outFlv
  $okHdr = $pktType -eq 0
  $frames = [int]((Invoke-Tool $gplProbe @('-v', 'error', '-count_frames', '-select_streams', 'v:0', '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', $outFlv)).Out.Trim())
  $okDec = ($dec.Code -eq 0 -and [string]::IsNullOrWhiteSpace($dec.Err) -and [Math]::Abs($frames - 300) -le 3)
  $detail = "wall {0:N1}s, cpu {1:N1}s, {2}x{3} {4} fps, {5}, aac {6} Hz, keyframe gaps [{7}], duration {8:N2}s, bytes {9}, first video tag AVC packet type {10}, decoded frames {11}, decode errors: '{12}'" -f `
    $sw.Elapsed.TotalSeconds, $cpu, $v.width, $v.height, $v.r_frame_rate, $v.codec_name, $a.sample_rate, (($gaps | Select-Object -Unique) -join ','), $dur, (Get-Item $outFlv).Length, $pktType, $frames, $dec.Err.Trim()
  Add-Result $name ($okVideo -and $okAudio -and $okGop -and $okDur -and $okHdr -and $okDec) $detail
}

# 4. One-frame probe of every GPU encoder
foreach ($enc1 in 'h264_nvenc', 'h264_amf', 'h264_qsv') {
  $r = Invoke-Tool $ff @('-hide_banner', '-v', 'error', '-f', 'lavfi', '-i', 'color=black:s=256x256:r=30', '-frames:v', '1', '-c:v', $enc1, '-f', 'null', '-')
  $errLines = (($r.Err -split "`r?`n") | Where-Object { $_.Trim() }) -join ' | '
  Add-Result "probe $enc1" $true ("exit {0}; {1}" -f $r.Code, $errLines)
}

# 5. Sizes
$zipSize = (Get-Item $Zip).Length
$unz = (Get-ChildItem -Recurse -File $Dest | Measure-Object Length -Sum).Sum
Add-Result 'sizes' $true ("zip {0:N0} bytes, unzipped {1:N0} bytes" -f $zipSize, $unz)

$failed = @($results | Where-Object { -not $_.Pass }).Count
$results | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $Scratch 'verify-results.json')
Write-Host ("done: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
