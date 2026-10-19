@echo off
setlocal EnableExtensions
title Lionfell crash reporter
set "LF_SELF=%~f0"
set "LF_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = [IO.File]::ReadAllText($env:LF_SELF); $i = $s.IndexOf('#LIONFELL' + '-PS'); if ($i -lt 0) { throw 'Reporter script missing' }; Invoke-Expression $s.Substring($i)"
echo.
pause
exit /b %ERRORLEVEL%

#LIONFELL-PS
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = $env:LF_DIR
$exe = Join-Path $dir 'otclient.exe'
$hostName = $env:LIONFELL_HOST
if (-not $hostName) { $hostName = '100.111.197.66' }
$url = $env:LIONFELL_REPORT_URL
if (-not $url) { $url = "http://$($hostName):4000/api/crashes" }

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    Write-Host 'otclient.exe was not found beside this launcher.' -ForegroundColor Red
    exit 1
}

function Scrub-Text([string]$text) {
    if ($env:USERPROFILE) {
        $text = [regex]::Replace($text, [regex]::Escape($env:USERPROFILE), '%USERPROFILE%', 'IgnoreCase')
    }
    $text = [regex]::Replace($text, '(?im)^.*(?:password|passwd|authorization|bearer|secret|session|api[_-]?key|token).*$', '[redacted credential line]')
    $text = [regex]::Replace($text, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '[email]')
    return $text
}

function Read-Log([string]$path, [int]$tail, [int]$maxChars) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'not found' }
    try {
        $text = (Get-Content -LiteralPath $path -Tail $tail -ErrorAction Stop | Out-String)
        if ($text.Length -gt $maxChars) { $text = '[earlier lines omitted]' + "`r`n" + $text.Substring($text.Length - $maxChars) }
        return (Scrub-Text $text)
    } catch {
        return "could not read: $($_.Exception.Message)"
    }
}

function Get-FileState([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'missing' }
    $file = Get-Item -LiteralPath $path
    return "size=$($file.Length) modified=$($file.LastWriteTimeUtc.ToString('o'))"
}

function Find-Relaunch([datetime]$since, [int]$oldPid) {
    $until = (Get-Date).AddSeconds(8)
    do {
        try {
            $candidate = Get-CimInstance Win32_Process -Filter "Name = 'otclient.exe'" -ErrorAction Stop |
                Where-Object { $_.ProcessId -ne $oldPid -and $_.ExecutablePath -eq $exe -and $_.CreationDate -ge $since } |
                Sort-Object CreationDate -Descending | Select-Object -First 1
            if ($candidate) { return $candidate.ProcessId }
        } catch { }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $until)
    return $null
}

function Find-RecentDump([datetime]$since) {
    $until = (Get-Date).AddSeconds(6)
    $folders = @($reportDir)
    if ($env:LOCALAPPDATA) { $folders += (Join-Path $env:LOCALAPPDATA 'CrashDumps') }
    do {
        foreach ($folder in $folders) {
            $file = Get-ChildItem -LiteralPath $folder -Filter 'otclient.exe*.dmp' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $since.ToUniversalTime().AddSeconds(-2) } |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($file) { return $file.FullName }
        }
        if ($env:ProgramData) {
            foreach ($area in @('ReportArchive', 'ReportQueue')) {
                $werFolder = Join-Path $env:ProgramData ("Microsoft\Windows\WER\$area")
                $recent = Get-ChildItem -LiteralPath $werFolder -Directory -Filter 'AppCrash_otclient.exe*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTimeUtc -ge $since.ToUniversalTime().AddSeconds(-2) } |
                    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 4
                foreach ($entry in $recent) {
                    $file = Get-ChildItem -LiteralPath $entry.FullName -File -Filter '*.dmp' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                    if ($file) { return $file.FullName }
                }
            }
        }
        try {
            $events = Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1001; StartTime=$since} -ErrorAction Stop |
                Where-Object { $_.Message -match '(?i)otclient\.exe' } | Select-Object -First 4
            foreach ($event in $events) {
                foreach ($line in ($event.Message -split '\r?\n')) {
                    $path = $line.Trim()
                    if ($path -match '(?i)\.dmp$' -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                        return $path
                    }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $until)
    return $null
}

if ($env:LOCALAPPDATA) {
    $reportDir = Join-Path $env:LOCALAPPDATA 'Lionfell\CrashReports'
} else {
    $reportDir = Join-Path $dir 'CrashReports'
}
[IO.Directory]::CreateDirectory($reportDir) | Out-Null

Write-Host 'Lionfell crash reporter' -ForegroundColor Yellow
Write-Host 'Play normally. If the game crashes, a detailed report will be sent to the Lionfell website.'
Write-Host 'The report includes game logs, Windows error events, system details, and a Windows crash dump when available.'
Write-Host 'A dump contains process memory and may include private session data. Local copies are saved.'
Write-Host ''

$started = Get-Date
$crashPaths = @((Join-Path $dir 'crashreport.log'), (Join-Path $dir 'crash_report.log'))
$before = @{}
foreach ($path in $crashPaths) { $before[$path] = Get-FileState $path }
$launchError = ''
$exitCode = $null
$relaunch = $false
$updateExpected = $false
$firstLog = 'not captured'

try {
    $process = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru -ErrorAction Stop
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $firstLog = Read-Log (Join-Path $dir 'otclient.log') 500 45000
    $recentLog = Read-Log (Join-Path $dir 'otclient.log') 12 4000
    $updateExpected = $recentLog -match '(?i)Lionfell update .* installed .* restarting'
    if ($exitCode -eq 0) {
        $nextPid = Find-Relaunch $started $process.Id
        if ($nextPid) {
            $relaunch = $true
            Write-Host 'The updater restarted Lionfell; watching the new game window.'
            $next = Get-Process -Id $nextPid -ErrorAction SilentlyContinue
            if ($next) {
                $next.WaitForExit()
                $exitCode = $next.ExitCode
            }
        }
    }
} catch {
    $launchError = $_.Exception.ToString()
}

$freshCrashLog = $false
foreach ($path in $crashPaths) {
    if ((Get-FileState $path) -ne $before[$path] -and (Test-Path -LiteralPath $path)) {
        $freshCrashLog = $true
    }
}

if (-not $launchError -and $exitCode -eq 0 -and -not $freshCrashLog -and -not ($updateExpected -and -not $relaunch)) {
    Write-Host 'Lionfell closed normally. No report was sent.' -ForegroundColor Green
    exit 0
}

Write-Host 'Collecting crash details...'
$dumpPath = Find-RecentDump $started
$localDump = $null
$compressedDump = $null
$dumpNote = 'Windows did not leave an accessible dump for this crash.'
if ($dumpPath) {
    try {
        $localDump = Join-Path $reportDir ('dump-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.dmp')
        Copy-Item -LiteralPath $dumpPath -Destination $localDump -ErrorAction Stop
        $compressedDump = $localDump + '.gz'
        $inputFile = [IO.File]::OpenRead($localDump)
        try {
            $outputFile = [IO.File]::Create($compressedDump)
            try {
                $gzip = [IO.Compression.GZipStream]::new($outputFile, [IO.Compression.CompressionLevel]::Optimal)
                try { $inputFile.CopyTo($gzip) } finally { $gzip.Dispose() }
            } finally { $outputFile.Dispose() }
        } finally { $inputFile.Dispose() }
        $dumpNote = "captured=$([IO.Path]::GetFileName($localDump)) size=$((Get-Item -LiteralPath $localDump).Length) compressed=$((Get-Item -LiteralPath $compressedDump).Length)"
    } catch {
        $dumpNote = "A dump was found but could not be copied: $($_.Exception.Message)"
        $compressedDump = $null
    }
}
$parts = New-Object 'System.Collections.Generic.List[string]'
function Add-Part([string]$heading, [string]$value) {
    $script:parts.Add("==== $heading ====")
    $script:parts.Add((Scrub-Text $value))
    $script:parts.Add('')
}

Add-Part 'Run' "started=$($started.ToUniversalTime().ToString('o'))`r`nended=$((Get-Date).ToUniversalTime().ToString('o'))`r`nexit_code=$exitCode`r`nupdate_expected=$updateExpected`r`nrelaunch_seen=$relaunch`r`nlaunch_error=$launchError"
Add-Part 'Crash dump' $dumpNote
Add-Part 'Windows' (cmd /c ver | Out-String)
try {
    Add-Part 'Operating system' (Get-CimInstance Win32_OperatingSystem | Format-List Caption,Version,BuildNumber,OSArchitecture,TotalVisibleMemorySize,FreePhysicalMemory | Out-String)
    Add-Part 'Processor' (Get-CimInstance Win32_Processor | Format-List Name,NumberOfCores,NumberOfLogicalProcessors | Out-String)
    Add-Part 'Graphics and driver' (Get-CimInstance Win32_VideoController | Format-List Name,DriverVersion,DriverDate,CurrentHorizontalResolution,CurrentVerticalResolution,AdapterRAM | Out-String)
} catch { Add-Part 'System query error' $_.Exception.Message }

$fileLines = New-Object 'System.Collections.Generic.List[string]'
foreach ($name in @('otclient.exe', 'init.lua', 'lionfell.bat', 'lionfell-report.bat', 'data\things\1310\catalog-content.json', 'data\sounds\1310\catalog-sound.json')) {
    $fileLines.Add("$name`: $(Get-FileState (Join-Path $dir $name))")
}
try { $fileLines.Add("otclient.exe SHA256: $((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash)") } catch { }
Add-Part 'Game files' ($fileLines -join "`r`n")

foreach ($path in $crashPaths) {
    Add-Part ("Game crash log: " + [IO.Path]::GetFileName($path)) (Read-Log $path 400 30000)
}
Add-Part 'Game log: first run' $firstLog
Add-Part 'Game log: otclient.log' (Read-Log (Join-Path $dir 'otclient.log') 500 45000)

try {
    $events = Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$started.AddMinutes(-5)} -ErrorAction Stop |
        Where-Object { $_.Message -match '(?i)otclient\.exe|lionfell' } |
        Select-Object -First 8 TimeCreated,ProviderName,Id,LevelDisplayName,Message |
        Format-List | Out-String
    Add-Part 'Windows application errors' $events
} catch { Add-Part 'Windows application errors' "could not query: $($_.Exception.Message)" }

$report = $parts -join "`r`n"
while ([Text.Encoding]::UTF8.GetByteCount($report) -gt 85000) {
    $report = $report.Substring(0, [int]($report.Length * 0.85)) + "`r`n[report truncated to fit upload limit]"
}

$reportPath = Join-Path $reportDir ('report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
[IO.File]::WriteAllText($reportPath, $report, (New-Object Text.UTF8Encoding($false)))
Write-Host "Local report: $reportPath"

try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($report)
    $request = [Net.HttpWebRequest]::Create($url)
    $request.Method = 'POST'
    $request.Accept = 'application/json'
    $request.ContentType = 'text/plain; charset=utf-8'
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $request.ContentLength = $bytes.Length
    $stream = $request.GetRequestStream()
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        $answer = $reader.ReadToEnd() | ConvertFrom-Json
        if (-not $answer.ok -or -not $answer.id) { throw 'The website did not confirm saving the report.' }
        Write-Host "Report uploaded. ID: $($answer.id)" -ForegroundColor Green
    } finally { $response.Close() }
} catch {
    Write-Host "Upload failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Keep the local report and send that file to the server owner.'
    exit 1
}

if (-not $compressedDump) {
    Write-Host 'No Windows dump was available to upload. The text report was sent.' -ForegroundColor Yellow
    exit 0
}

$dumpInfo = Get-Item -LiteralPath $compressedDump
Write-Host "Local dump: $compressedDump"
if ($dumpInfo.Length -gt 64000000) {
    Write-Host 'The compressed dump is over 64 MB, so it was kept locally.' -ForegroundColor Yellow
    exit 0
}

try {
    $dumpRequest = [Net.HttpWebRequest]::Create("$url/$($answer.id)/dump")
    $dumpRequest.Method = 'POST'
    $dumpRequest.Accept = 'application/json'
    $dumpRequest.ContentType = 'application/gzip'
    $dumpRequest.AllowWriteStreamBuffering = $false
    $dumpRequest.Timeout = 300000
    $dumpRequest.ReadWriteTimeout = 300000
    $dumpRequest.ContentLength = $dumpInfo.Length
    $dumpInput = [IO.File]::OpenRead($compressedDump)
    try {
        $dumpStream = $dumpRequest.GetRequestStream()
        try { $dumpInput.CopyTo($dumpStream) } finally { $dumpStream.Close() }
    } finally { $dumpInput.Close() }
    $dumpResponse = $dumpRequest.GetResponse()
    try {
        $dumpReader = New-Object IO.StreamReader($dumpResponse.GetResponseStream())
        $dumpAnswer = $dumpReader.ReadToEnd() | ConvertFrom-Json
        if (-not $dumpAnswer.ok) { throw 'The website did not confirm saving the dump.' }
        Write-Host "Crash dump uploaded with report $($answer.id)." -ForegroundColor Green
    } finally { $dumpResponse.Close() }
} catch {
    Write-Host "Dump upload failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Keep the local dump and send it to the server owner.'
    exit 1
}
