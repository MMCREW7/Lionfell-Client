@echo off
rem Lionfell manual updater for Windows. Put it in the Lionfell folder (next to otclient.exe) and
rem double-click it. It downloads whatever changed in the latest release from the Lionfell
rem website, the same files the game's own updater would fetch, then offers to start the game.
rem Needs only what comes with Windows (PowerShell). Set LIONFELL_HOST to use another address.
setlocal
set "LF_SELF=%~f0"
set "LF_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = [IO.File]::ReadAllText($env:LF_SELF); $i = $s.IndexOf('#LIONFELL' + '-PS'); Invoke-Expression $s.Substring($i)"
echo.
pause
exit /b

#LIONFELL-PS
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$hostName = $env:LIONFELL_HOST
if (-not $hostName) { $hostName = '100.111.197.66' }
$base = "http://$($hostName):4000/updates/"
$dir = $env:LF_DIR

Write-Host 'Lionfell updater' -ForegroundColor Yellow
Write-Host "Folder: $dir"
if (-not (Test-Path -LiteralPath (Join-Path $dir 'otclient.exe'))) {
    Write-Host 'otclient.exe is not in this folder. Put lionfell-update.bat in your Lionfell folder and run it from there.' -ForegroundColor Red
    return
}

# the game has to be closed while its files are replaced
$running = Get-Process -Name 'otclient' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) }
if ($running) {
    Write-Host 'Lionfell is running. Close the game first, then press Enter (or type Y and Enter to close it now).' -ForegroundColor Yellow
    $answer = Read-Host
    if ($answer -match '^[yY]') { $running | Stop-Process -Force; Start-Sleep -Seconds 2 }
    if (Get-Process -Name 'otclient' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) }) {
        Write-Host 'The game is still running; nothing was changed.' -ForegroundColor Red
        return
    }
}

# CRC32 the way the release manifest writes it (lowercase hex, no leading zeros)
if (-not ('LionfellCrc' -as [type])) {
    Add-Type -TypeDefinition @'
public static class LionfellCrc {
    static readonly uint[] Table = MakeTable();
    static uint[] MakeTable() {
        var t = new uint[256];
        for (uint i = 0; i < 256; i++) {
            uint c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[i] = c;
        }
        return t;
    }
    public static string OfFile(string path) {
        uint crc = 0xFFFFFFFFu;
        var buffer = new byte[1 << 16];
        using (var f = System.IO.File.OpenRead(path)) {
            int n;
            while ((n = f.Read(buffer, 0, buffer.Length)) > 0)
                for (int i = 0; i < n; i++) crc = Table[(crc ^ buffer[i]) & 0xFF] ^ (crc >> 8);
        }
        return (crc ^ 0xFFFFFFFFu).ToString("x");
    }
}
'@
}

Write-Host "Checking for updates at $base ..."
$web = New-Object System.Net.WebClient
try {
    $manifest = $web.DownloadString($base + 'manifest.json') | ConvertFrom-Json
} catch {
    Write-Host "Couldn't reach the Lionfell website ($base). Are you connected to Tailscale?" -ForegroundColor Red
    return
}

# what to fetch: every release file that is missing or different, plus the Windows program
$wanted = @()
foreach ($entry in $manifest.files.PSObject.Properties) {
    $path = $entry.Name
    if ($path -match '\.\.' -or $path.StartsWith('/')) { continue }
    $wanted += [pscustomobject]@{ Path = $path; Checksum = [string]$entry.Value }
}
if ($manifest.binary_windows) {
    $wanted += [pscustomobject]@{ Path = [string]$manifest.binary_windows.file; Checksum = [string]$manifest.binary_windows.checksum }
}
$toFetch = @()
foreach ($file in $wanted) {
    $local = Join-Path $dir ($file.Path -replace '/', '\')
    if (-not (Test-Path -LiteralPath $local) -or [LionfellCrc]::OfFile($local) -ne $file.Checksum) { $toFetch += $file }
}
if ($toFetch.Count -eq 0) {
    Write-Host "Lionfell is up to date (release $($manifest.version))." -ForegroundColor Green
} else {
    Write-Host "Updating $($toFetch.Count) files (release $($manifest.version)) ..."
    $failed = 0
    $done = 0
    foreach ($file in $toFetch) {
        $done++
        $local = Join-Path $dir ($file.Path -replace '/', '\')
        $temp = "$local.download"
        try {
            $folder = Split-Path $local -Parent
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            $web.DownloadFile($base + $file.Path, $temp)
            if ([LionfellCrc]::OfFile($temp) -ne $file.Checksum) { throw 'the download was damaged' }
            Move-Item -LiteralPath $temp -Destination $local -Force
            Write-Host ("  [{0}/{1}] {2}" -f $done, $toFetch.Count, $file.Path)
        } catch {
            $failed++
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
            Write-Host ("  [{0}/{1}] {2}: FAILED ({3})" -f $done, $toFetch.Count, $file.Path, $_.Exception.Message) -ForegroundColor Red
        }
    }
    # leftovers from the in-game updater's program swap
    foreach ($old in @('otclient.exe.new', 'otclient.exe.old')) {
        $p = Join-Path $dir $old
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    if ($failed -gt 0) {
        Write-Host "$failed files failed. Run lionfell-update.bat again." -ForegroundColor Red
        return
    }
    Write-Host 'Update finished.' -ForegroundColor Green
}

$start = Read-Host 'Start Lionfell now? (Y/n)'
if ($start -notmatch '^[nN]') {
    Start-Process -FilePath (Join-Path $dir 'otclient.exe') -WorkingDirectory $dir
}
