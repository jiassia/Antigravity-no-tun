[CmdletBinding()]
param(
    [ValidateSet('Launch','Repair','Cli','Diagnose','Restore')][string]$Mode='Launch',
    [switch]$NoDelay,
    [switch]$Installed,
    [string]$LegacyRoot
)

$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$global:LASTEXITCODE=0

function Move-LegacyState([string]$FromRoot, [string]$ToRoot) {
    if (-not $FromRoot) { return }
    $device=$env:COMPUTERNAME+'-'+$env:USERNAME
    $from=Join-Path $FromRoot ('backups\'+$device)
    $to=Join-Path $ToRoot ('backups\'+$device)
    if (-not (Test-Path -LiteralPath (Join-Path $from 'state.json') -PathType Leaf) -or
        (Test-Path -LiteralPath $to)) { return }
    $parent=Split-Path $to -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary=Join-Path $parent ('.migration-'+[guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $from -Destination $temporary -Recurse
        $manifest=Join-Path $temporary 'state.json'
        $state=Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $fromPrefix=[IO.Path]::GetFullPath($from).TrimEnd('\')+'\'
        foreach ($record in @($state.shortcuts)) {
            if ($record.backup) {
                $old=[IO.Path]::GetFullPath([string]$record.backup)
                if ($old.StartsWith($fromPrefix,[StringComparison]::OrdinalIgnoreCase)) {
                    $record.backup=Join-Path $to $old.Substring($fromPrefix.Length)
                }
            }
        }
        if ($state.pendingGuiSession) {
            $old=[IO.Path]::GetFullPath([string]$state.pendingGuiSession)
            if ($old.StartsWith($fromPrefix,[StringComparison]::OrdinalIgnoreCase)) {
                $state.pendingGuiSession=Join-Path $to $old.Substring($fromPrefix.Length)
            }
        }
        $oldLauncher=Join-Path $FromRoot 'Antigravity优化.ps1'
        $roots=@($state.launcherPaths | Where-Object { $_ })+@($oldLauncher) | Select-Object -Unique
        $state | Add-Member -NotePropertyName launcherPaths -NotePropertyValue @($roots) -Force
        $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifest -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $to
        Write-Host '已迁移此设备的原设置备份。'
    } finally {
        $allowed=[IO.Path]::GetFullPath($parent).TrimEnd('\')+'\'
        if (([IO.Path]::GetFullPath($temporary)).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

try {
    if (-not $Installed) {
        if (-not $env:LOCALAPPDATA) { throw '未找到当前用户的本地应用数据目录。' }
        $installRoot=Join-Path $env:LOCALAPPDATA 'AntigravityProxyHelper'
        $runtime=Join-Path $installRoot 'app'
        $files=@('launcher.ps1','Antigravity优化.ps1',
            'launcher-src\DetachedProcess.cs','launcher-src\GuiSession.ps1',
            'launcher-src\GuiSessionTransport.cs','launcher-src\capture-gui-drafts.js',
            'launcher-src\restore-gui-drafts.js','launcher-src\ProxyBridge.ps1','launcher-src\CliEnvironment.ps1','launcher-src\WindowsProxy.ps1','launcher-src\SocksBridge.cs',
            'launcher-src\SocksBridge.ps1')
        foreach ($file in $files) {
            if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) {
                throw ('运行文件不完整：'+$file+'。请重新下载完整文件。')
            }
        }
        $installLock=New-Object Threading.Mutex -ArgumentList @($false,('Local\AntigravityProxyInstall-'+$env:USERNAME))
        $ownInstallLock=$false
        try {
            try { $ownInstallLock=$installLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownInstallLock=$true }
            if (-not $ownInstallLock) { throw '另一个启动过程正在运行，请稍候。' }
            New-Item -ItemType Directory -Path $runtime -Force | Out-Null
            if (-not $LegacyRoot) { $LegacyRoot=$PSScriptRoot }
            Move-LegacyState $LegacyRoot $runtime
            foreach ($file in $files) {
                $target=Join-Path $runtime $file
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                if ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot $file)) -ine [IO.Path]::GetFullPath($target)) {
                    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $target -Force
                }
            }
            # Optional machine-specific settings are never replaced during an upgrade.
            $targetConfig=Join-Path $runtime 'proxy-config.json'
            $sourceConfig=Join-Path $PSScriptRoot 'proxy-config.json'
            if (-not (Test-Path -LiteralPath $sourceConfig -PathType Leaf) -and $LegacyRoot) {
                $sourceConfig=Join-Path $LegacyRoot 'proxy-config.json'
            }
            if (-not (Test-Path -LiteralPath $targetConfig)) {
                if (Test-Path -LiteralPath $sourceConfig -PathType Leaf) {
                    Copy-Item -LiteralPath $sourceConfig -Destination $targetConfig
                } else {
                    '{"appPath":"","cliPath":"","proxyUrl":""}' | Set-Content -LiteralPath $targetConfig -Encoding UTF8
                }
            }
            $restorePath=Join-Path $installRoot '恢复原设置.bat'
            $restore=@'
@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\launcher.ps1" -Mode Restore -Installed
echo.
pause
'@
            [IO.File]::WriteAllText($restorePath,($restore -replace "`r?`n","`r`n"),[Text.Encoding]::ASCII)
        } finally {
            if ($ownInstallLock) { $installLock.ReleaseMutex() }
            $installLock.Dispose()
        }
        & (Join-Path $runtime 'launcher.ps1') -Mode $Mode -NoDelay:$NoDelay -Installed
        $result=$LASTEXITCODE
        exit $result
    }

    Write-Host 'Antigravity 普通代理自动配置与启动' -ForegroundColor Cyan
    Write-Host '正在运行，下面会实时显示当前步骤。'
    Write-Host ''
    & (Join-Path $PSScriptRoot 'Antigravity优化.ps1') -Mode $Mode -NoPause
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    if ($Mode -eq 'Launch' -and -not $NoDelay) {
        Write-Host ''
        Write-Host '操作完成。窗口将在 5 秒后自动关闭。' -ForegroundColor Green
        Start-Sleep -Seconds 5
    }
    exit 0
} catch {
    Write-Host ('失败：'+$_.Exception.Message) -ForegroundColor Red
    exit 1
}
