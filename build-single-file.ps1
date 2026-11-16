[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
$files=@(
    'launcher.ps1', 'Antigravity优化.ps1',
    'launcher-src\DetachedProcess.cs', 'launcher-src\GuiSession.ps1',
    'launcher-src\GuiSessionTransport.cs', 'launcher-src\capture-gui-drafts.js',
    'launcher-src\restore-gui-drafts.js', 'launcher-src\ProxyBridge.ps1', 'launcher-src\SocksBridge.cs',
    'launcher-src\SocksBridge.ps1'
)

$memory=New-Object IO.MemoryStream
$archive=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Create,$true)
try {
    foreach ($file in $files) {
        $source=Join-Path $PSScriptRoot $file
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing required file: $file" }
        $entry=$archive.CreateEntry($file.Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal)
        $destination=$entry.Open()
        $inputStream=[IO.File]::OpenRead($source)
        try { $inputStream.CopyTo($destination) } finally { $inputStream.Dispose(); $destination.Dispose() }
    }
} finally { $archive.Dispose() }
$encoded=[Convert]::ToBase64String($memory.ToArray())
$memory.Dispose()

# The BAT contains only ASCII and an embedded ZIP. The readable sources remain in this repository.
$bootstrap=@'
$ErrorActionPreference='Stop';$result=1;$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';$tmp=Join-Path $base ('AntigravityProxy-'+[guid]::NewGuid().ToString('N'));try{$data=[IO.File]::ReadAllText($env:AGY_SINGLE_FILE);$marker=':AGY_EMBEDDED_ZIP:';$index=$data.LastIndexOf($marker,[StringComparison]::Ordinal);if($index -lt 0){throw 'Package data is missing.'};[IO.Directory]::CreateDirectory($tmp)|Out-Null;$zip=Join-Path $tmp 'payload.zip';[IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String($data.Substring($index+$marker.Length)));Add-Type -AssemblyName System.IO.Compression.FileSystem;[IO.Compression.ZipFile]::ExtractToDirectory($zip,(Join-Path $tmp 'payload'));& (Join-Path $tmp 'payload\launcher.ps1') -LegacyRoot ([IO.Path]::GetDirectoryName($env:AGY_SINGLE_FILE));$result=$LASTEXITCODE}catch{Write-Host ('Startup failed: '+$_.Exception.Message) -ForegroundColor Red}finally{if(([IO.Path]::GetFullPath($tmp)).StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $tmp)){Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}};exit $result
'@.Trim()
$lines=New-Object 'System.Collections.Generic.List[string]'
$lines.Add('@echo off')
$lines.Add('setlocal DisableDelayedExpansion')
$lines.Add('title Antigravity Proxy Helper')
$lines.Add('set "AGY_SINGLE_FILE=%~f0"')
$lines.Add('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "'+$bootstrap+'"')
$lines.Add('set "AGY_EXIT_CODE=%errorlevel%"')
$lines.Add('if not "%AGY_EXIT_CODE%"=="0" (')
$lines.Add('  echo.')
$lines.Add('  echo Setup did not complete. See the message above.')
$lines.Add('  pause')
$lines.Add(')')
$lines.Add('exit /b %AGY_EXIT_CODE%')
$lines.Add(':AGY_EMBEDDED_ZIP:')
for ($i=0;$i -lt $encoded.Length;$i+=120) {
    $lines.Add($encoded.Substring($i,[Math]::Min(120,$encoded.Length-$i)))
}
$target=Join-Path $PSScriptRoot '一键启动.bat'
[IO.File]::WriteAllText($target,(($lines -join "`r`n")+"`r`n"),[Text.Encoding]::ASCII)
Write-Host "Created: $target"
