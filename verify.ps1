<#
.SYNOPSIS
  Verifies a kulisa-ffmpeg win64 zip on Windows.

.DESCRIPTION
  Extracts the zip into a new empty directory, then runs the checks of the release process:
    1. license, configure line (LGPL 2.1 or later; a non-empty option list, equal to the one in
       BUILDINFO.txt, without gpl, nonfree or version3), the exact file set of the zip and the notices
    2. encoders, hwaccels and filters of the allow list, compared by exact name
    3. H.264 plus AAC FLV transcode through stdin and stdout with h264_mf (hw_encoding 0 and 1)
    4. one-frame probe of every GPU encoder
    5. sizes
  A GPU probe and the hw_encoding 1 run may fail on a machine without that GPU, but only cleanly: a
  negative AVERROR exit code and a known FFmpeg error line in stderr. A crash (an NTSTATUS exit code
  such as 0xC0000005 or 0xC0000135) or an empty stderr fails the check.
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

# Names of a "-encoders" or "-filters" listing: the second column of every line after the "------"
# separator (the first column holds the flags).
function Get-ListedNames([string]$text) {
  $names = [System.Collections.Generic.List[string]]::new()
  $inList = $false
  foreach ($line in ($text -split "`r?`n")) {
    if (-not $inList) { if ($line -match '^\s*-{6}\s*$') { $inList = $true }; continue }
    $cols = $line.Trim() -split '\s+'
    if ($cols.Count -ge 2) { $names.Add($cols[1]) }
  }
  return , $names.ToArray()
}

# Names of a "-hwaccels" listing: every line after the title line.
function Get-HwaccelNames([string]$text) {
  $lines = @(($text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  return , @($lines | Where-Object { $_ -notmatch ':$' })
}

# Values of the given allow list variable in the components file.
function Get-ComponentList([string]$name) {
  foreach ($line in Get-Content $Components) {
    if ($line -cmatch "^$name=`"(.*)`"$") { return , @($Matches[1] -split '\s+' | Where-Object { $_ }) }
  }
  throw "no $name in $Components"
}

# AVERROR values FFmpeg can return as its exit code: negative errno values and the FFERRTAG codes.
function Get-FfErrTag([int]$a, [int]$b, [int]$c, [int]$d) { return -($a -bor ($b -shl 8) -bor ($c -shl 16) -bor ($d -shl 24)) }
$averrorTags = @(
  (Get-FfErrTag 0xF8 66 83 70),  # BSF_NOT_FOUND
  (Get-FfErrTag 66 85 71 33),    # BUG
  (Get-FfErrTag 66 85 71 32),    # BUG2
  (Get-FfErrTag 0xF8 68 69 67),  # DECODER_NOT_FOUND
  (Get-FfErrTag 0xF8 68 69 77),  # DEMUXER_NOT_FOUND
  (Get-FfErrTag 0xF8 69 78 67),  # ENCODER_NOT_FOUND
  (Get-FfErrTag 69 79 70 32),    # EOF
  (Get-FfErrTag 69 88 73 84),    # EXIT
  (Get-FfErrTag 69 88 84 32),    # EXTERNAL
  (Get-FfErrTag 0xF8 70 73 76),  # FILTER_NOT_FOUND
  (Get-FfErrTag 73 78 68 65),    # INVALIDDATA
  (Get-FfErrTag 0xF8 77 85 88),  # MUXER_NOT_FOUND
  (Get-FfErrTag 0xF8 79 80 84),  # OPTION_NOT_FOUND
  (Get-FfErrTag 80 65 87 69),    # PATCHWELCOME
  (Get-FfErrTag 0xF8 80 82 79),  # PROTOCOL_NOT_FOUND
  (Get-FfErrTag 0xF8 83 84 82),  # STREAM_NOT_FOUND
  (Get-FfErrTag 85 78 75 78),    # UNKNOWN
  -0x2bb2afa8                    # EXPERIMENTAL
)
# Error lines of an encoder that cannot open because the GPU, its driver or its runtime is missing.
$knownErrorLines = @(
  'Error while opening encoder',
  'Could not open encoder',
  'Cannot load ',
  'failed to open',
  'Error creating a MFX session',
  'could not find any MFT',
  'could not create MFT',
  'Driver does not support the required nvenc API version',
  'No capable devices found',
  'No NVENC capable devices found'
)

# A clean FFmpeg failure: a negative AVERROR exit code and a known error line in a non-empty stderr.
# Exit codes from 0xC0000000 up (as unsigned) are NTSTATUS codes of a crash or a loader failure,
# except the negative errno range -1 to -4095 (0xFFFFF001 to 0xFFFFFFFF), which AVERROR(errno) uses.
function Test-CleanFailure([int]$code, [string]$stderr) {
  $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($code), 0)
  $isErrno = $code -le -1 -and $code -ge -4095
  $isTag = $averrorTags -contains $code
  $hex = '0x{0:X8}' -f $unsigned
  if ($code -ge 0) { return [pscustomobject]@{ Ok = $false; Why = "exit $code ($hex) is not an error code" } }
  if (-not ($isErrno -or $isTag)) {
    $kind = if ($unsigned -ge 0xC0000000) { 'NTSTATUS' } else { 'unknown' }
    return [pscustomobject]@{ Ok = $false; Why = "exit $code ($hex) is $kind, not an AVERROR code" }
  }
  if ([string]::IsNullOrWhiteSpace($stderr)) { return [pscustomobject]@{ Ok = $false; Why = "exit $code ($hex) with an empty stderr" } }
  $hit = @($knownErrorLines | Where-Object { $stderr.Contains($_) })
  if ($hit.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Why = "exit $code ($hex) without a known error line" } }
  return [pscustomobject]@{ Ok = $true; Why = "clean failure, exit $code ($hex), matched '" + ($hit -join "', '") + "'" }
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
$bcText | Set-Content -Path (Join-Path $Scratch 'buildconf.txt')
# The configure line exactly as -buildconf prints it: the title line "  configuration:" and one
# "    --option" line per option.
$bcLines = @(($bcText -split "`r?`n") | Where-Object { $_.Trim() -ne '' })
$bcStart = [Array]::IndexOf($bcLines, '  configuration:')
$bcBlock = @()
if ($bcStart -ge 0) {
  for ($i = $bcStart; $i -lt $bcLines.Count; $i++) {
    if ($i -gt $bcStart -and $bcLines[$i] -notmatch '^    --') { break }
    $bcBlock += $bcLines[$i]
  }
}
# The same block in BUILDINFO.txt (a blank line ends it).
$infoLines = @(Get-Content (Join-Path $Dest 'BUILDINFO.txt'))
$start = [Array]::IndexOf($infoLines, '  configuration:')
$block = @()
if ($start -ge 0) {
  for ($i = $start; $i -lt $infoLines.Count -and $infoLines[$i].Trim() -ne ''; $i++) { $block += $infoLines[$i] }
}
$bcOptions = @($bcBlock | Where-Object { $_ -match '^    --' })
$infoOptions = @($block | Where-Object { $_ -match '^    --' })
$forbidden = @('--enable-gpl', '--enable-nonfree', '--enable-version3') | Where-Object { $bcText -match [regex]::Escape($_) }
$bcEqual = ($bcOptions.Count -gt 0) -and ($infoOptions.Count -gt 0) -and (($block -join "`n") -ceq ($bcBlock -join "`n"))
Add-Result 'buildconf' ((@($forbidden).Count -eq 0) -and $bcEqual) ("{0} options printed by -buildconf, {1} in BUILDINFO.txt, equal and not empty: {2}; forbidden switches: {3}" -f $bcOptions.Count, $infoOptions.Count, $bcEqual, $(if (@($forbidden).Count -eq 0) { 'none' } else { $forbidden -join ',' }))

# The exact file set of the zip: bin\ffmpeg.exe, one DLL per FFmpeg library (the major version of each
# library is read from "ffmpeg -version"), LICENSE.txt, BUILDINFO.txt and every file of licenses\. A
# missing file, an extra file and a directory entry all fail the check.
$ver = Invoke-Tool $ff @('-hide_banner', '-version')
$libs = @(Get-ComponentList 'LIBRARIES')
$dlls = @()
foreach ($lib in $libs) {
  if (($ver.Out + $ver.Err) -match "(?m)^lib$lib\s+(\d+)\.") { $dlls += "bin/$lib-$($Matches[1]).dll" } else { $dlls += "bin/$lib-<major not found>.dll" }
}
$expectedFiles = @('bin/ffmpeg.exe') + $dlls + @('LICENSE.txt', 'BUILDINFO.txt',
  'licenses/AMF-LICENSE.txt', 'licenses/FFmpeg-LICENSE.md', 'licenses/FFmpeg-third-party-notices.txt',
  'licenses/libstdc++-notices.txt', 'licenses/libvpl-LICENSE.txt', 'licenses/mingw-w64-headers-notices.txt',
  'licenses/mingw-w64-runtime.txt', 'licenses/nv-codec-headers-LICENSE.txt')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipHandle = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Zip).Path)
$zipNames = @($zipHandle.Entries | ForEach-Object { $_.FullName })
$zipHandle.Dispose()
$missingFiles = @($expectedFiles | Where-Object { $zipNames -cnotcontains $_ })
$extraFiles = @($zipNames | Where-Object { $expectedFiles -cnotcontains $_ })
Add-Result 'zip contents' ($missingFiles.Count -eq 0 -and $extraFiles.Count -eq 0) ("{0} files expected, {1} in the zip; missing: {2}; extra: {3}" -f $expectedFiles.Count, $zipNames.Count, ($missingFiles -join ','), ($extraFiles -join ','))
# The notices name their license families; IJG code needs its sentence, the mingw-w64 runtime its
# ZPL and gdtoa notices, the libvpl dispatcher's libstdc++ headers their HP and SGI notices and the GCC
# Runtime Library Exception, and the FFmpeg blocks that name an origin the license text of that origin.
function Get-NoticeText([string]$name) {
  $path = Join-Path $Dest ('licenses\' + $name)
  if (Test-Path $path) { return Get-Content -Raw $path } else { return '' }
}
$notices = Get-NoticeText 'FFmpeg-third-party-notices.txt'
$mingw = Get-NoticeText 'mingw-w64-runtime.txt'
$stdcxx = Get-NoticeText 'libstdc++-notices.txt'
$amf = Get-NoticeText 'AMF-LICENSE.txt'
$families = if ($notices -match '(?m)^Licenses: (.*)$') { $Matches[1].Trim() } else { '' }
$ijgOk = ($families -cnotmatch '\bIJG\b') -or $notices.Contains('This software is based in part on the work of the Independent JPEG Group.')
$mingwOk = $mingw.Contains('License: ZPL-2.1') -and $mingw.Contains('License: Lucent')
$originsOk = $notices.Contains('Aaron D. Gifford') -and $notices.Contains('Nicolas P. Rougier') -and $notices.Contains('DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE') -and $notices.Contains('Boost Software License - Version 1.0')
$stdcxxOk = $stdcxx.Contains('Hewlett-Packard') -and $stdcxx.Contains('Silicon Graphics') -and $stdcxx.Contains('GCC RUNTIME LIBRARY EXCEPTION')
$amfOk = $amf.Contains('Advanced Micro Devices') -and $amf.Contains('Permission is hereby granted')
Add-Result 'notices' ($families -ne '' -and $ijgOk -and $mingwOk -and $originsOk -and $stdcxxOk -and $amfOk) ("families: {0}; IJG sentence ok: {1}; mingw-w64 ZPL and Lucent: {2}; origin texts: {3}; libstdc++ HP, SGI and runtime exception: {4}; AMF: {5}" -f $families, $ijgOk, $mingwOk, $originsOk, $stdcxxOk, $amfOk)

# 2. Encoders, hwaccels, filters, compared by exact (case-sensitive) name
# Encoders: exactly the allow list (h264_mf, h264_nvenc, h264_amf, h264_qsv, aac and wrapped_avframe).
$encNames = Get-ListedNames (Invoke-Tool $ff @('-hide_banner', '-encoders')).Out
$wantedEnc = Get-ComponentList 'ENCODERS'
$missingEnc = @($wantedEnc | Where-Object { $encNames -cnotcontains $_ })
$extraEnc = @($encNames | Where-Object { $wantedEnc -cnotcontains $_ })
Add-Result 'encoders' ($missingEnc.Count -eq 0 -and $extraEnc.Count -eq 0) ("listed: {0}; missing: {1}; not in the allow list: {2}" -f ($encNames -join ','), ($missingEnc -join ','), ($extraEnc -join ','))
# Hwaccels: exactly d3d11va, cuda, qsv and amf.
$hwNames = Get-HwaccelNames (Invoke-Tool $ff @('-hide_banner', '-hwaccels')).Out
$wantedHw = @('d3d11va', 'cuda', 'qsv', 'amf')
$missingHw = @($wantedHw | Where-Object { $hwNames -cnotcontains $_ })
$extraHw = @($hwNames | Where-Object { $wantedHw -cnotcontains $_ })
Add-Result 'hwaccels' ($missingHw.Count -eq 0 -and $extraHw.Count -eq 0) ("listed: {0}; missing: {1}; unexpected: {2}" -f ($hwNames -join ','), ($missingHw -join ','), ($extraHw -join ','))
# Filters: every filter of the allow list (FFmpeg adds the few its command line tool needs).
$filterNames = Get-ListedNames (Invoke-Tool $ff @('-hide_banner', '-filters')).Out
$wanted = Get-ComponentList 'FILTERS'
$missingF = @($wanted | Where-Object { $filterNames -cnotcontains $_ })
$extraF = @($filterNames | Where-Object { $wanted -cnotcontains $_ })
Add-Result 'filters' ($missingF.Count -eq 0) ("wanted {0}, listed {1}, missing: {2}; added by FFmpeg: {3}" -f $wanted.Count, $filterNames.Count, ($missingF -join ','), ($extraF -join ','))

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
    $errAll = Get-Content -Raw $errTxt -ErrorAction SilentlyContinue
    if ($null -eq $errAll) { $errAll = '' }
    $lastErr = ((($errAll -split "`r?`n") | Where-Object { $_ -match 'rror|fail|Cannot|Unknown|could not' } | Select-Object -Last 5) -join ' | ')
    # hw_encoding=1 needs a hardware MFT: on a machine without one it may fail, but only cleanly.
    $clean = Test-CleanFailure $code $errAll
    $ok = ($hwEnc -eq 1) -and $clean.Ok
    Add-Result $name $ok ("{0}; wall {1:N1}s, cpu {2:N1}s, error: {3}" -f $clean.Why, $sw.Elapsed.TotalSeconds, $cpu, $lastErr)
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
  if ($r.Code -eq 0) {
    Add-Result "probe $enc1" $true ("encoded one frame, exit 0; {0}" -f $errLines)
  } else {
    $clean = Test-CleanFailure $r.Code $r.Err
    Add-Result "probe $enc1" $clean.Ok ("{0}; {1}" -f $clean.Why, $errLines)
  }
}

# 5. Sizes
$zipSize = (Get-Item $Zip).Length
$unz = (Get-ChildItem -Recurse -File $Dest | Measure-Object Length -Sum).Sum
Add-Result 'sizes' $true ("zip {0:N0} bytes, unzipped {1:N0} bytes" -f $zipSize, $unz)

$failed = @($results | Where-Object { -not $_.Pass }).Count
$results | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $Scratch 'verify-results.json')
Write-Host ("done: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
