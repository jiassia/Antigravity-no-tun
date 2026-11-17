[CmdletBinding()]
param(
    [ValidateSet('Launch','Repair','Cli','Diagnose','Restore')][string]$Mode = 'Launch',
    [string]$AppPath, [string]$CliPath, [string]$ProxyUrl,
    [int]$ShortcutId = -1, [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) }
$script:Root = $PSScriptRoot
$script:StatusPath = Join-Path $script:Root 'Antigravity-launch-status.json'
$script:StateDir = Join-Path $script:Root ('backups\' + $env:COMPUTERNAME + '-' + $env:USERNAME)
$script:ManifestPath = Join-Path $script:StateDir 'state.json'
$script:Proxy = $null
$script:Gui = $null
$script:Cli = $null
$script:Changes = @()
$script:ProcessCache = $null
$script:ShortcutCache = $null
$script:RunLock = $null
$script:OwnLock = $false
. (Join-Path $script:Root 'launcher-src\ProxyBridge.ps1')
. (Join-Path $script:Root 'launcher-src\CliEnvironment.ps1')
. (Join-Path $script:Root 'launcher-src\WindowsProxy.ps1')
function Write-Stage([int]$Number, [string]$Text) {
    Write-Host ('['+(Get-Date -Format 'HH:mm:ss')+'] ['+$Number+'/6] '+$Text) -ForegroundColor Cyan
}

function Write-Status([string]$Status, [string]$Detail) {
    [ordered]@{ time=(Get-Date).ToString('o'); status=$Status; detail=$Detail; machine=$env:COMPUTERNAME;
        proxy=$script:Proxy; appPath=$script:Gui; cliPath=$script:Cli; changes=@($script:Changes) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StatusPath -Encoding UTF8
}
function Read-State {
    if (Test-Path -LiteralPath $script:ManifestPath) { return (Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json) }
    return $null
}
function Save-State($State) {
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    $temp = $script:ManifestPath + '.tmp'
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $script:ManifestPath -Force
}
function Get-Processes {
    if ($null -eq $script:ProcessCache) {
        try { $script:ProcessCache = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { $script:ProcessCache = @() }
    }
    return $script:ProcessCache
}
function Get-ShortcutFiles {
    if ($null -ne $script:ShortcutCache) { return $script:ShortcutCache }
    $script:ShortcutCache = @()
    $dirs=@([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'),[Environment]::GetFolderPath('CommonStartMenu')) | Select-Object -Unique
    foreach ($dir in $dirs) {
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            $script:ShortcutCache += @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)
        }
    }
    return $script:ShortcutCache
}
function Find-Apps {
    $guiCandidates = New-Object 'System.Collections.Generic.List[string]'
    $cliCandidates = New-Object 'System.Collections.Generic.List[string]'
    if ($AppPath -and -not (Test-Path -LiteralPath $AppPath -PathType Leaf)) { throw "指定的软件不存在：$AppPath" }
    if ($CliPath -and -not (Test-Path -LiteralPath $CliPath -PathType Leaf)) { throw "指定的 CLI 不存在：$CliPath" }
    if ($AppPath) { $guiCandidates.Add($AppPath) }
    if ($CliPath) { $cliCandidates.Add($CliPath) }
    foreach ($p in (Get-Processes)) {
        if ($p.Name -ieq 'Antigravity.exe' -and $p.ExecutablePath) { $guiCandidates.Add($p.ExecutablePath) }
        if ($p.Name -ieq 'agy.exe' -and $p.ExecutablePath) { $cliCandidates.Add($p.ExecutablePath) }
    }
    foreach ($name in @('agy.exe','agy.cmd','agy.bat','agy','antigravity.exe','antigravity.cmd','antigravity')) {
        foreach ($cmd in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            if ($cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
                if ($name -like 'agy*') { $cliCandidates.Add($cmd.Source) }
                if ([IO.Path]::GetFileName($cmd.Source) -ieq 'Antigravity.exe') { $guiCandidates.Add($cmd.Source) }
                if ([IO.Path]::GetFileName((Split-Path $cmd.Source -Parent)) -ieq 'bin') {
                    $parent = Split-Path (Split-Path $cmd.Source -Parent) -Parent
                    if ($parent) { $guiCandidates.Add((Join-Path $parent 'Antigravity.exe')) }
                }
            }
        }
    }
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\Antigravity.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\Antigravity.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Antigravity.exe')) {
        try {
            $value=(Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
            if ($value) { $guiCandidates.Add([Environment]::ExpandEnvironmentVariables($value.Trim('"'))) }
        } catch { }
    }
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $entry=Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($entry -and $entry.DisplayName -match '^Antigravity(?:\s|$)') {
                if ($entry.InstallLocation) {
                    $location=[Environment]::ExpandEnvironmentVariables($entry.InstallLocation.Trim('"'))
                    $guiCandidates.Add((Join-Path $location 'Antigravity.exe'))
                }
                if ($entry.DisplayIcon -match '^\s*"?(.+?\.exe)"?(?:,\s*\d+)?\s*$') {
                    $guiCandidates.Add([Environment]::ExpandEnvironmentVariables($Matches[1]))
                }
            }
        }
    }
    foreach ($base in @($env:LOCALAPPDATA,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432)) {
        if (-not $base) { continue }
        foreach ($sub in @('Programs\Antigravity\Antigravity.exe','Antigravity\Antigravity.exe')) { $guiCandidates.Add((Join-Path $base $sub)) }
    }
    foreach ($base in @($env:LOCALAPPDATA,$env:USERPROFILE,$env:APPDATA)) {
        if (-not $base) { continue }
        foreach ($sub in @('agy\bin\agy.exe','agy\bin\agy.cmd','agy\bin\agy.bat','.agy\bin\agy.exe','.agy\bin\agy.cmd','.agy\bin\agy.bat',
            '.antigravity\bin\agy.exe','.antigravity\bin\agy.cmd','.antigravity\bin\agy.bat','scoop\shims\agy.exe','scoop\shims\agy.cmd','scoop\shims\agy.bat','npm\agy.cmd','npm\agy.bat')) {
            $cliCandidates.Add((Join-Path $base $sub))
        }
    }
    $shortcuts=@(Get-ShortcutFiles)
    if ($shortcuts.Count) {
        try { $shell=New-Object -ComObject WScript.Shell } catch { $shell=$null }
        if ($shell) {
            foreach ($file in $shortcuts) {
                try {
                    $link=$shell.CreateShortcut($file.FullName)
                    if ([IO.Path]::GetFileName($link.TargetPath) -ieq 'Antigravity.exe') { $guiCandidates.Add($link.TargetPath) }
                    if ($link.IconLocation -match '^\s*"?(.+?\.exe)"?(?:,\s*\d+)?\s*$' -and [IO.Path]::GetFileName($Matches[1]) -ieq 'Antigravity.exe') {
                        $guiCandidates.Add($Matches[1])
                    }
                } catch { }
            }
        }
    }
    $old=Read-State
    if ($old -and $old.appPath -is [string] -and $old.appPath) { $guiCandidates.Add($old.appPath) }
    if ($old -and $old.cliPath -is [string] -and $old.cliPath) { $cliCandidates.Add($old.cliPath) }
    $script:Gui=$null
    $guiMatch=$guiCandidates | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) -and [IO.Path]::GetFileName($_) -ieq 'Antigravity.exe' } | Select-Object -First 1
    if ($guiMatch) { $script:Gui=[string]$guiMatch }
    if ($script:Gui) {
        $appDir=Split-Path $script:Gui -Parent
        foreach ($sub in @('bin\agy.exe','bin\agy.cmd','bin\agy.bat','resources\app\bin\agy.exe','resources\app\bin\agy.cmd','resources\app\bin\agy.bat')) {
            $cliCandidates.Add((Join-Path $appDir $sub))
        }
    }
    $script:Cli=$null
    $cliMatch=$cliCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($cliMatch) { $script:Cli=[string]$cliMatch }
    if (-not $script:Gui -and -not $script:Cli) { throw '没有找到 Antigravity 或 agy CLI。请先安装软件；便携安装可在 proxy-config.json 指定 appPath / cliPath。' }
}
function Test-Port([uri]$Uri) {
    $ip=$null
    if ([Net.IPAddress]::TryParse($Uri.DnsSafeHost,[ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        $client=New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetworkV6)
    } else { $client=New-Object Net.Sockets.TcpClient }
    try {
        $pending=$client.BeginConnect($Uri.DnsSafeHost,$Uri.Port,$null,$null)
        if (-not $pending.AsyncWaitHandle.WaitOne(500)) { return $false }
        $client.EndConnect($pending); return $true
    } catch { return $false } finally { $client.Dispose() }
}
function Add-ProxyCandidate($List,[string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    try {
        $Value=$Value.Trim()
        if ($Value -notmatch '^\w+://') { $Value='http://' + $Value }
        $uri=[uri]$Value
        if ($uri.Scheme -ne 'http' -or $uri.Port -lt 1 -or $uri.Port -gt 65535 -or $uri.UserInfo -or
            $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { return }
        $hostName=$uri.DnsSafeHost
        $address=$null
        if ($hostName -ine 'localhost' -and (-not [Net.IPAddress]::TryParse($hostName,[ref]$address) -or
            (-not $address.Equals([Net.IPAddress]::Loopback) -and -not $address.Equals([Net.IPAddress]::IPv6Loopback)))) { return }
        $normalized=$uri.GetLeftPart([UriPartial]::Authority)
        if ($address -and $address.Equals([Net.IPAddress]::IPv6Loopback)) { $normalized='http://[::1]:'+$uri.Port }
        if (-not $List.Contains($normalized)) { $List.Add($normalized) }
    } catch { }
}
function Get-ProxyCandidates {
    $list=New-Object 'System.Collections.Generic.List[string]'
    if ($ProxyUrl) { Add-ProxyCandidate $list $ProxyUrl; return ,$list }
    $configDirs=@()
    if ($env:APPDATA) {
        foreach ($sub in @('io.github.clash-verge-rev.clash-verge-rev','io.github.clash-verge.clash-verge',
            'clash-verge','Clash for Windows','xyz.nyanpasu.clash-nyanpasu','clash-nyanpasu','mihomo-party')) {
            $configDirs+=Join-Path $env:APPDATA $sub
        }
    }
    if ($env:USERPROFILE) {
        foreach ($sub in @('.config\clash','.config\mihomo','.config\clash-nyanpasu')) { $configDirs+=Join-Path $env:USERPROFILE $sub }
    }
    $configFiles=@()
    $processes=@(Get-Processes)
    foreach ($p in $processes) {
        if ($p.Name -match '(?i)^(?:mihomo|clash)' -and $p.CommandLine) {
            if ($p.CommandLine -match '(?:^|\s)-d(?:\s+|=)(?:"([^"]+)"|(\S+))') { $configDirs+=($Matches[1]+$Matches[2]) }
            if ($p.CommandLine -match '(?:^|\s)-f(?:\s+|=)(?:"([^"]+)"|(\S+))') { $configFiles+=($Matches[1]+$Matches[2]) }
        }
    }
    foreach ($dir in ($configDirs | Select-Object -Unique)) {
        foreach ($name in @('clash-verge.yaml','config.yaml','config.yml','mihomo.yaml')) {
            $file=Join-Path $dir $name
            $configFiles+=$file
        }
    }
    foreach ($file in ($configFiles | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            foreach ($line in @(Select-String -LiteralPath $file -Pattern '^["'']?(?:mixed-port|port|verge_mixed_port|verge_port)["'']?\s*:\s*["'']?(\d+)["'']?\s*(?:#.*)?$' -ErrorAction SilentlyContinue)) {
                Add-ProxyCandidate $list ('127.0.0.1:'+$line.Matches[0].Groups[1].Value)
            }
        }
    }
    $sys=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($sys -and $sys.ProxyEnable -eq 1) {
        foreach ($part in ($sys.ProxyServer -split ';')) {
            $part=$part.Trim()
            if ($part -match '^([a-z0-9]+)\s*=\s*(.*)$') {
                if ($Matches[1] -in @('http','https')) { Add-ProxyCandidate $list $Matches[2] }
            } else { Add-ProxyCandidate $list $part }
        }
    }
    foreach ($name in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY')) {
        foreach ($scope in @('Process','User','Machine')) { Add-ProxyCandidate $list ([Environment]::GetEnvironmentVariable($name,$scope)) }
    }
    foreach ($port in @(7897,7890,8080,10809,7899,20171,2080)) { Add-ProxyCandidate $list "127.0.0.1:$port" }
    $proxyPids=@($processes | Where-Object {
        $_.Name -match '(?i)(?:mihomo|clash|v2ray|xray|sing-box|singbox|nekoray|nekobox|hiddify|flclash|shadowsocks|sslocal|ss-local|qv2ray|netch|trojan|hysteria|tuic|naive|brook)'
    } | ForEach-Object { $_.ProcessId })
    if ($proxyPids.Count -and (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        try {
            foreach ($socket in @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
                $_.OwningProcess -in $proxyPids -and $_.LocalAddress -in @('127.0.0.1','0.0.0.0','::1','::')
            } | Select-Object -First 32)) {
                if ($socket.LocalAddress -in @('127.0.0.1','0.0.0.0','::')) { Add-ProxyCandidate $list ('127.0.0.1:'+$socket.LocalPort) }
                if ($socket.LocalAddress -in @('::1','::')) { Add-ProxyCandidate $list ('[::1]:'+$socket.LocalPort) }
            }
        } catch { }
    }
    return ,$list
}
function Test-HttpProxy([string]$Value) {
    if (-not (Test-Port ([uri]$Value))) { return $false }
    # Verify HTTP CONNECT, TLS and upstream access, not just a listening TCP port.
    try {
        $req=[Net.HttpWebRequest]::Create('https://www.google.com/generate_204')
        $req.Proxy=New-Object Net.WebProxy($Value)
        $req.Timeout=7000; $req.ReadWriteTimeout=7000; $req.AllowAutoRedirect=$false
        $response=$req.GetResponse()
        try { return ([int]$response.StatusCode -eq 204) } finally { $response.Close() }
    } catch { return $false }
}
function Get-ProxyClientPaths {
    $names=@('clash-verge.exe','Clash for Windows.exe','clash-nyanpasu.exe','Mihomo Party.exe',
        'mihomo-party.exe','clash-party.exe','ClashParty.exe','FlClash.exe','v2rayN.exe','Qv2ray.exe',
        'NekoRay.exe','NekoBox.exe','Netch.exe','Hiddify.exe','Shadowsocks.exe','ShadowsocksR-dotnet4.0.exe')
    $paths=New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in (Get-Processes)) {
        if ($p.ExecutablePath -and $p.Name -in $names) { $paths.Add($p.ExecutablePath) }
    }
    foreach ($base in @($env:LOCALAPPDATA,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432)) {
        if (-not $base) { continue }
        foreach ($sub in @('Programs\Clash Verge\clash-verge.exe','Clash Verge\clash-verge.exe',
            'Programs\Clash for Windows\Clash for Windows.exe','Clash for Windows\Clash for Windows.exe',
            'Programs\Clash Nyanpasu\clash-nyanpasu.exe','Clash Nyanpasu\clash-nyanpasu.exe',
            'Programs\Mihomo Party\Mihomo Party.exe','Mihomo Party\Mihomo Party.exe',
            'Programs\FlClash\FlClash.exe','FlClash\FlClash.exe','Programs\v2rayN\v2rayN.exe','v2rayN\v2rayN.exe',
            'Programs\Hiddify\Hiddify.exe','Hiddify\Hiddify.exe',
            'Programs\Shadowsocks\Shadowsocks.exe','Shadowsocks\Shadowsocks.exe')) { $paths.Add((Join-Path $base $sub)) }
    }
    if ($env:USERPROFILE) {
        foreach ($name in $names) { $paths.Add((Join-Path $env:USERPROFILE ('scoop\shims\'+$name))) }
    }
    foreach ($name in $names) {
        foreach ($cmd in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            if ($cmd.Source) { $paths.Add($cmd.Source) }
        }
        foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')) {
            try {
                $value=(Get-ItemProperty -LiteralPath (Join-Path $root $name) -ErrorAction Stop).'(default)'
                if ($value) { $paths.Add([Environment]::ExpandEnvironmentVariables($value.Trim('"'))) }
            } catch { }
        }
    }
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $entry=Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if (-not $entry -or $entry.DisplayName -notmatch '(?i)^(?:clash verge|clash for windows|clash nyanpasu|clash party|mihomo party|flclash|v2rayn|qv2ray|nekoray|nekobox|netch|hiddify|shadowsocks)(?:\s|$)') { continue }
            if ($entry.InstallLocation) {
                $location=[Environment]::ExpandEnvironmentVariables($entry.InstallLocation.Trim('"'))
                foreach ($name in $names) { $paths.Add((Join-Path $location $name)) }
            }
            if ($entry.DisplayIcon -match '^\s*"?(.+?\.exe)"?(?:,\s*\d+)?\s*$') { $paths.Add([Environment]::ExpandEnvironmentVariables($Matches[1])) }
        }
    }
    $shortcuts=@(Get-ShortcutFiles)
    if ($shortcuts.Count) {
        try { $shell=New-Object -ComObject WScript.Shell } catch { $shell=$null }
        if ($shell) {
            foreach ($file in $shortcuts) {
                try {
                    $target=$shell.CreateShortcut($file.FullName).TargetPath
                    if ($target -and [IO.Path]::GetFileName($target) -in $names) { $paths.Add($target) }
                } catch { }
            }
        }
    }
    return @($paths | Where-Object { [IO.Path]::GetFileName($_) -in $names -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)
}
function Start-Clash {
    $runningNames=@(Get-Processes | ForEach-Object { $_.Name })
    $target=@(Get-ProxyClientPaths | Where-Object { [IO.Path]::GetFileName($_) -notin $runningNames } | Select-Object -First 1)
    if (-not $target.Count) { return }
    try {
        Write-Host '正在启动已安装的代理客户端...'
        Start-Process -FilePath $target[0] -WorkingDirectory (Split-Path $target[0] -Parent) -WindowStyle Hidden -ErrorAction Stop
        $script:ProcessCache=$null
    } catch {
        Write-Host '代理客户端未能启动，请手动打开后重试。' -ForegroundColor Yellow
        return
    }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $checked=@{}
    do {
        Write-Host '  等待代理客户端就绪并检查普通代理...'
        foreach ($candidate in (Get-ProxyCandidates)) {
            if ($timer.Elapsed.TotalSeconds -ge 20) { break }
            if ($checked.ContainsKey($candidate) -and ($timer.Elapsed.TotalSeconds - $checked[$candidate]) -lt 5) { continue }
            if (-not (Test-Port ([uri]$candidate))) { continue }
            $checked[$candidate]=$timer.Elapsed.TotalSeconds
            if (Test-HttpProxy $candidate) { $script:Proxy=$candidate; return }
        }
        foreach ($port in (Get-SocksPorts)) { if (Test-SocksPort $port) { return } }
        if ($timer.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Seconds 1 }
    } while ($timer.Elapsed.TotalSeconds -lt 20)
}
function Resolve-Proxy {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $candidates=Get-ProxyCandidates
    Write-Host ('  已收集 '+$candidates.Count+' 个普通代理候选地址。')
    foreach ($candidate in $candidates) {
        Write-Host ('  正在检查 '+$candidate+'：端口、HTTP CONNECT 和 HTTPS 连通性...')
        if (Test-HttpProxy $candidate) { $script:Proxy=$candidate; Use-ExistingBridge $candidate; return }
        Write-Host ('  '+$candidate+' 未通过，继续检查下一个候选。')
    }
    if (Find-UsableSocksBridge) { return }
    if (-not $ProxyUrl -and $Mode -ne 'Diagnose') {
        Start-Clash
        if ($script:Proxy) { Use-ExistingBridge $script:Proxy; return }
        $script:ProcessCache=$null
        if (Find-UsableSocksBridge) { return }
    }
    if ($ProxyUrl) {
        throw '指定的代理未通过检查。请检查本机 HTTP、mixed 或无认证 SOCKS5 端口和节点。'
    }
    throw '没有找到能访问 Google 的本机 HTTP、mixed 或无认证 SOCKS5 代理。请检查代理客户端和节点是否可用。'
}
function Broadcast-Environment {
    if (-not ('AgyProxy.EnvironmentNotice' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace AgyProxy { public class EnvironmentNotice {
[DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);
}}
'@
    }
    $result=[UIntPtr]::Zero
    [AgyProxy.EnvironmentNotice]::SendMessageTimeout([IntPtr]0xffff,0x1a,[UIntPtr]::Zero,'Environment',2,3000,[ref]$result) | Out-Null
}
function Get-UserEnvironment([string]$Name) { return [Environment]::GetEnvironmentVariable($Name,'User') }
function Set-UserEnvironment([string]$Name,$Value) { [Environment]::SetEnvironmentVariable($Name,$Value,'User') }
function Set-ProxyEnvironment([switch]$Persist) {
    $existing=Get-UserEnvironment 'NO_PROXY'
    $noProxy=(@(($existing -split ',') | Where-Object { $_ -and $_ -notmatch '^\s*\*\s*$' }) + @('localhost','127.0.0.1','::1') | Select-Object -Unique) -join ','
    $values=[ordered]@{HTTP_PROXY=$script:Proxy;HTTPS_PROXY=$script:Proxy;ALL_PROXY=$script:Proxy;NO_PROXY=$noProxy}
    if ($Persist) {
        $state=Read-State
        if (-not $state) {
            $original=[ordered]@{}
            foreach ($name in $values.Keys) { $original[$name]=Get-UserEnvironment $name }
            $state=[pscustomobject]@{created=(Get-Date).ToString('o');appPath=$script:Gui;cliPath=$script:Cli; environment=[pscustomobject]$original;shortcuts=@()}
            Save-State $state
        }
        if ($script:Cli) { Ensure-CliPath $script:Cli $state | Out-Null }
        if ($script:Bridge) { Set-BridgeStartup $state }
        Set-WindowsProxy $script:Proxy $state | Out-Null
        if (-not $state.appliedEnvironment) {
            $state | Add-Member -NotePropertyName appliedEnvironment -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        foreach ($name in $values.Keys) {
            if ((Get-UserEnvironment $name) -ne $values[$name]) {
                Write-Host ('  正在设置 '+$name+'...')
                Set-UserEnvironment $name $values[$name]
            } else { Write-Host ('  '+$name+' 已配置。') }
            $state.appliedEnvironment | Add-Member -NotePropertyName $name -NotePropertyValue $values[$name] -Force
            Save-State $state
        }
        if (-not $script:Bridge) { Remove-BridgeStartup $state }
        Write-Host '  正在通知 Windows 更新用户环境变量...'
        Broadcast-Environment
        $script:Changes+='已设置用户级 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY'
    }
    foreach ($name in $values.Keys) { [Environment]::SetEnvironmentVariable($name,$values[$name],'Process') }
}
function Test-ManagedShortcut($Link,$State) {
    $launchers=@((Join-Path $script:Root 'Antigravity优化.ps1'))+@($State.launcherPaths | Where-Object { $_ })
    foreach ($path in $launchers) {
        if ($Link.Arguments -and $Link.Arguments.IndexOf([string]$path,[StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}
function Repair-Shortcuts {
    if (-not $script:Gui) { return }
    $state=Read-State
    $state.appPath=$script:Gui; $state.cliPath=$script:Cli
    $shell=New-Object -ComObject WScript.Shell
    $launcher=Join-Path $script:Root 'Antigravity优化.ps1'
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $foundDesktop=$false
    foreach ($file in (Get-ShortcutFiles)) {
        try {
            $link=$shell.CreateShortcut($file.FullName)
            $record=@($state.shortcuts | Where-Object { $_.path -eq $file.FullName }) | Select-Object -First 1
            if (-not $record -and $link.TargetPath -ine $script:Gui) { continue }
            if ($record -and $link.TargetPath -ine $script:Gui -and -not (Test-ManagedShortcut $link $state)) { continue }
            if (-not $record) {
                $id=@($state.shortcuts).Count
                $backup=Join-Path $script:StateDir ("shortcut-$id.lnk")
                Copy-Item -LiteralPath $file.FullName -Destination $backup
                $record=[pscustomobject]@{id=$id;path=$file.FullName;backup=$backup;arguments=$link.Arguments;created=$false}
                $state.shortcuts=@($state.shortcuts)+@($record); Save-State $state
            }
            $link.TargetPath=$ps
            $link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$launcher+'" -Mode Launch -ShortcutId '+$record.id
            $link.WorkingDirectory=$script:Root; $link.IconLocation=$script:Gui+',0'; $link.Save()
            foreach ($desktop in @([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('CommonDesktopDirectory'))) {
                if ($desktop -and $file.FullName.StartsWith($desktop.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { $foundDesktop=$true }
            }
            $script:Changes+='已修复快捷方式：'+$file.FullName
            Write-Host ('  图标已配置：'+$file.FullName)
        } catch {
            $script:Changes+='快捷方式未修改（权限或文件占用）：'+$file.FullName
            Write-Host ('  图标未修改（权限或占用）：'+$file.FullName) -ForegroundColor Yellow
        }
    }
    if (-not $foundDesktop) {
        $path=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Antigravity（普通代理）.lnk'
        if (Test-Path -LiteralPath $path) { $path=Join-Path ([Environment]::GetFolderPath('Desktop')) ('Antigravity（普通代理）-'+(Get-Date -Format 'yyyyMMddHHmmss')+'.lnk') }
        $id=@($state.shortcuts).Count
        $record=[pscustomobject]@{id=$id;path=$path;backup=$null;arguments='';created=$true}
        $state.shortcuts=@($state.shortcuts)+@($record); Save-State $state
        $link=$shell.CreateShortcut($path); $link.TargetPath=$ps
        $link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$launcher+'" -Mode Launch -ShortcutId '+$id
        $link.WorkingDirectory=$script:Root; $link.IconLocation=$script:Gui+',0'; $link.Save()
        $script:Changes+='已创建桌面普通代理图标：'+$path
        Write-Host ('  已创建桌面入口：'+$path)
    }
    Save-State $state
}
function Start-Gui {
    if (-not $script:Gui) { Write-Host '未安装 GUI；CLI 配置已完成。'; return }
    $argument='--proxy-server='+$script:Proxy
    $state=Read-State; $originalArgs=''
    if ($state -and $ShortcutId -ge 0) {
        $record=@($state.shortcuts | Where-Object { $_.id -eq $ShortcutId }) | Select-Object -First 1
        if ($record) { $originalArgs=$record.arguments -replace '(?:^|\s)--proxy-server=(?:"[^"]*"|\S+)','' }
    }
    . (Join-Path $script:Root 'launcher-src\GuiSession.ps1')
    $main=@(Get-AntigravityGuiProcesses $script:Gui) | Select-Object -First 1
    $savedSession=$null
    if ($state.pendingGuiSession -and -not (Test-Path -LiteralPath $state.pendingGuiSession -PathType Leaf)) {
        throw '上次保存的草稿副本不存在，已保留恢复记录，请检查备份目录。'
    }
    if ($state.pendingGuiSession) {
        $savedSession=Get-Content -LiteralPath $state.pendingGuiSession -Raw | ConvertFrom-Json
        $savedSession | Add-Member -NotePropertyName backupPath -NotePropertyValue $state.pendingGuiSession -Force
    }
    $knownDetached=$state -and $state.guiDetachedOutput -eq 1 -and $state.guiSessionVersion -eq 1 -and $state.guiProcessId -eq $main.ProcessId
    if ($main -and ($main.CommandLine -notlike ('*'+$argument+'*') -or -not $knownDetached)) {
        $savedSession=Stop-AntigravityGuiForRestart $main
        $state | Add-Member -NotePropertyName pendingGuiSession -NotePropertyValue $savedSession.backupPath -Force
        Save-State $state
        $main=$null
    }
    if (-not ('AgyProxy.DetachedProcess' -as [type])) {
        Write-Host '  正在准备 GUI 的独立输出句柄...'
        Add-Type -Path (Join-Path $script:Root 'launcher-src\DetachedProcess.cs')
    }
    $appPid=[AgyProxy.DetachedProcess]::Start($script:Gui,($argument+' '+$originalArgs).Trim(),(Split-Path $script:Gui -Parent))
    Write-Host ('  GUI 启动请求已发出，进程 ID：'+$appPid)
    if ($state) {
        $trackedPid=$appPid
        if ($main) { $trackedPid=$main.ProcessId }
        $state | Add-Member -NotePropertyName guiDetachedOutput -NotePropertyValue 1 -Force
        $state | Add-Member -NotePropertyName guiProcessId -NotePropertyValue $trackedPid -Force
        $state | Add-Member -NotePropertyName guiSessionVersion -NotePropertyValue 1 -Force
        Save-State $state
    }
    $script:Changes+='已启动/显示 GUI（独立输出句柄），进程 ID：'+$appPid
    Restore-AntigravityGuiSession $savedSession $script:Gui
    if ($savedSession -and $state) {
        $state | Add-Member -NotePropertyName pendingGuiSession -NotePropertyValue $null -Force
        Save-State $state
    }
}
function Restore-Settings {
    $state=Read-State
    if (-not $state) { throw '这台设备没有可恢复的备份。' }
    $errors=New-Object 'System.Collections.Generic.List[string]'
    foreach ($record in @($state.shortcuts)) {
        try {
            if ($record.created) {
                if (Test-Path -LiteralPath $record.path) {
                    $link=(New-Object -ComObject WScript.Shell).CreateShortcut($record.path)
                    if (Test-ManagedShortcut $link $state) { Remove-Item -LiteralPath $record.path }
                }
            } elseif ($record.backup -and (Test-Path -LiteralPath $record.backup -PathType Leaf)) {
                if (Test-Path -LiteralPath $record.path) {
                    $current=(New-Object -ComObject WScript.Shell).CreateShortcut($record.path)
                    if (-not (Test-ManagedShortcut $current $state)) { continue }
                }
                Copy-Item -LiteralPath $record.backup -Destination $record.path -Force
            } else {
                $errors.Add('快捷方式备份不存在：'+$record.path)
            }
        } catch { $errors.Add('快捷方式恢复失败：'+$record.path) }
    }
    foreach ($prop in $state.environment.PSObject.Properties) {
        try {
            $applied=if ($state.appliedEnvironment) { $state.appliedEnvironment.PSObject.Properties[$prop.Name] } else { $null }
            if ($applied -and (Get-UserEnvironment $prop.Name) -cne $applied.Value) {
                Write-Host ('保留后来更改的环境变量：'+$prop.Name) -ForegroundColor Yellow
                continue
            }
            Set-UserEnvironment $prop.Name $prop.Value
        } catch { $errors.Add('环境变量恢复失败：'+$prop.Name) }
    }
    try { Restore-CliPath $state | Out-Null } catch { $errors.Add('agy 命令路径恢复失败。') }
    try { Restore-WindowsProxy $state | Out-Null } catch { $errors.Add('Windows 代理设置恢复失败。') }
    try { Remove-BridgeStartup $state } catch { $errors.Add('本机代理转换服务的自启动项恢复失败。') }
    Stop-OwnedBridges
    Broadcast-Environment
    if ($errors.Count) { throw ('部分设置未恢复：'+($errors -join '；')) }
    Move-Item -LiteralPath $script:ManifestPath -Destination (Join-Path $script:StateDir ('restored-'+(Get-Date -Format 'yyyyMMddHHmmssfff')+'.json'))
    Write-Status 'restored' '已恢复原用户环境变量和快捷方式。请重新打开终端。'
    Write-Host '已恢复。请重新打开终端；已运行的软件需重新启动。'
}
try {
    $script:RunLock=New-Object Threading.Mutex -ArgumentList @($false,('Local\AntigravityProxyRepair-'+$env:USERNAME))
    try { $script:OwnLock=$script:RunLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $script:OwnLock=$true }
    if (-not $script:OwnLock) { Write-Host '代理启动/修复正在进行，请稍候。'; exit 1 }
    if ($Mode -eq 'Restore') { Restore-Settings; exit 0 }
    $config=Join-Path $script:Root 'proxy-config.json'
    if (Test-Path -LiteralPath $config) {
        $settings=Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        if (-not $AppPath -and $settings.appPath) { $AppPath=[Environment]::ExpandEnvironmentVariables($settings.appPath) }
        if (-not $CliPath -and $settings.cliPath) { $CliPath=[Environment]::ExpandEnvironmentVariables($settings.cliPath) }
        if (-not $ProxyUrl -and $settings.proxyUrl) { $ProxyUrl=$settings.proxyUrl }
    }
    Write-Stage 1 '查找 Antigravity GUI 和 agy CLI 安装位置'
    Find-Apps
    if ($Mode -eq 'Launch' -and -not $script:Gui -and $script:Cli) {
        Write-Host '未找到图形界面，正在配置并启动 agy CLI。'
        $Mode='Cli'
    }
    if ($Mode -eq 'Cli' -and -not $script:Cli) { throw '没有找到 agy CLI，请先安装后重试。' }
    Write-Host ('GUI: '+$script:Gui); Write-Host ('CLI: '+$script:Cli)
    Write-Stage 2 '检测普通代理并验证网络连接'
    Resolve-Proxy
    Write-Host ('普通代理可访问 Google：'+$script:Proxy)
    if ($Mode -eq 'Diagnose') { Write-Status 'diagnosed' '安装定位及 HTTP CONNECT / Google HTTPS 检查通过，未修改设置。'; exit 0 }
    Write-Stage 3 '配置 GUI 和 CLI 的代理环境'
    Set-ProxyEnvironment -Persist
    Write-Stage 4 '检查并修复桌面和开始菜单图标'
    if ($Mode -in @('Repair','Launch')) { Repair-Shortcuts }
    if ($Mode -in @('Launch','Cli')) { Write-Stage 5 '启动软件' }
    else { Write-Stage 5 '保留当前软件进程' }
    if ($Mode -eq 'Launch') { Start-Gui }
    if ($Mode -eq 'Cli') {
        if (-not $script:Cli) { throw '没有找到 agy CLI。请先安装 CLI。' }
        $env:AGY_PROXY_CLI=$script:Cli
        Write-Host '已配置代理，正在启动 agy CLI。'
        Write-Status 'cli_ready' 'CLI 终端已继承代理环境。'
        # Do not hold the setup lock during an interactive CLI session.
        if ($script:RunLock) {
            if ($script:OwnLock) { $script:RunLock.ReleaseMutex(); $script:OwnLock=$false }
            $script:RunLock.Dispose(); $script:RunLock=$null
        }
        & $script:Cli
        if ($LASTEXITCODE) { throw ('agy CLI 已退出，退出码：'+$LASTEXITCODE) }
        exit 0
    }
    Write-Status 'configured' '已配置普通代理和启动入口。已打开的终端需要重新打开。'
    Write-Stage 6 '完成'
    Write-Host '修复完成。以后双击桌面 Antigravity 图标即可；新终端中的 agy 会继承普通代理。'
    exit 0
} catch {
    try { Write-Status 'error' $_.Exception.Message } catch { }
    Write-Host ('失败：'+$_.Exception.Message) -ForegroundColor Red
    if ($NoPause) { exit 1 }
    (New-Object -ComObject WScript.Shell).Popup($_.Exception.Message,0,'Antigravity 普通代理修复',16) | Out-Null
    exit 1
} finally {
    Stop-NewBridgeIfUnused
    if ($script:RunLock) {
        if ($script:OwnLock) { $script:RunLock.ReleaseMutex() }
        $script:RunLock.Dispose()
    }
}
