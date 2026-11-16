# Discovery and lifecycle for the optional local HTTP-to-SOCKS5 bridge.
$script:Bridge=$null
$script:NewBridgeProcess=$null
$script:BridgePersisted=$false

function Get-SocksPorts {
    $ports=New-Object 'System.Collections.Generic.List[int]'
    function Add-Port($value) {
        $number=0
        if ([int]::TryParse([string]$value,[ref]$number) -and $number -gt 0 -and $number -le 65535 -and -not $ports.Contains($number)) {
            $ports.Add($number)
        }
    }
    function Add-Address([string]$address) {
        if (-not $address) { return }
        try {
            if ($address -notmatch '^\w+://') { $address='socks5://'+$address }
            $uri=[uri]$address
            if ($uri.Scheme -notin @('socks','socks5','socks5h') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
                $uri.AbsolutePath -ne '/' -or $uri.DnsSafeHost -notin @('localhost','127.0.0.1')) { return }
            Add-Port $uri.Port
        } catch { }
    }
    if ($ProxyUrl) { Add-Address $ProxyUrl; return ,$ports }
    $sys=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($sys -and $sys.ProxyEnable -eq 1) {
        foreach ($part in ($sys.ProxyServer -split ';')) {
            if ($part -match '^socks=(.+)$') { Add-Address $Matches[1] }
        }
    }
    foreach ($name in @('ALL_PROXY','HTTPS_PROXY','HTTP_PROXY')) {
        foreach ($scope in @('User','Process')) {
            $value=[Environment]::GetEnvironmentVariable($name,$scope)
            if ($value -match '^socks(?:5h?)?://') { Add-Address $value }
        }
    }
    $proxyPids=@(Get-Processes | Where-Object {
        $_.Name -match '(?i)(clash|mihomo|v2ray|xray|sing-box|singbox|nekoray|nekobox|hiddify|shadowsocks|sslocal|ss-local|trojan|hysteria|tuic|naive|brook|flclash|qv2ray|netch)'
    } | ForEach-Object { $_.ProcessId })
    if ($proxyPids.Count -and (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        try {
            foreach ($socket in @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
                $_.OwningProcess -in $proxyPids -and $_.LocalAddress -in @('127.0.0.1','0.0.0.0')
            } | Select-Object -First 48)) { Add-Port $socket.LocalPort }
        } catch { }
    }
    foreach ($port in @(10808,1080,7891,2080,1086,1081,7890,7897)) { Add-Port $port }
    return ,$ports
}

function Test-SocksPort([int]$Port) {
    $client=New-Object Net.Sockets.TcpClient
    try {
        $pending=$client.BeginConnect('127.0.0.1',$Port,$null,$null)
        if (-not $pending.AsyncWaitHandle.WaitOne(350)) { return $false }
        $client.EndConnect($pending)
        $stream=$client.GetStream(); $stream.ReadTimeout=1200; $stream.WriteTimeout=1200
        $hello=[byte[]]@(5,1,0); $stream.Write($hello,0,$hello.Length)
        $first=$stream.ReadByte(); $second=$stream.ReadByte()
        return ($first -eq 5 -and $second -eq 0)
    } catch { return $false } finally { $client.Dispose() }
}

function Get-OwnedBridgeProcesses {
    $path=[regex]::Escape((Join-Path $script:Root 'launcher-src\SocksBridge.ps1'))
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {
            $_.CommandLine -and $_.CommandLine -match ('(?i)(?:^|\s)-File\s+"?'+$path+'"?(?:\s|$)') -and
            $_.CommandLine -match '(?i)(?:^|\s)-UpstreamPort\s+\d+(?:\s|$)' -and
            $_.CommandLine -match '(?i)(?:^|\s)-ListenPort\s+\d+(?:\s|$)'
        })
    } catch { return @() }
}

function Use-ExistingBridge([string]$Proxy) {
    $state=Read-State
    if (-not $state -or -not $state.bridge -or $state.bridge.proxy -ne $Proxy) { return }
    $port=[int]$state.bridge.listenPort
    $upstream=[int]$state.bridge.upstreamPort
    $owned=@(Get-OwnedBridgeProcesses | Where-Object {
        $_.CommandLine -match ('(?i)(?:^|\s)-ListenPort\s+'+$port+'(?:\s|$)') -and
        $_.CommandLine -match ('(?i)(?:^|\s)-UpstreamPort\s+'+$upstream+'(?:\s|$)')
    })
    if ($owned.Count) { $script:Bridge=$state.bridge; $script:BridgePersisted=$true }
}

function Find-UsableSocksBridge {
    $ports=Get-SocksPorts
    Write-Host ('  正在检查 '+$ports.Count+' 个本机 SOCKS5 候选端口...')
    foreach ($port in $ports) {
        if (-not (Test-SocksPort $port)) { continue }
        Write-Host ('  发现 SOCKS5 端口 '+$port+'，正在验证网络连接...')
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        try { $listener.Start(); $localPort=([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
        $path=Join-Path $script:Root 'launcher-src\SocksBridge.ps1'
        $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$powershell
        $start.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$path+'" -UpstreamPort '+$port+' -ListenPort '+$localPort
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($start)
        $proxy='http://127.0.0.1:'+$localPort
        $ready=$false
        for ($i=0;$i -lt 80;$i++) {
            if ($process.HasExited) { break }
            if (Test-Port ([uri]$proxy)) { $ready=$true; break }
            Start-Sleep -Milliseconds 250
        }
        if ($ready -and -not $process.HasExited -and (Test-HttpProxy $proxy) -and -not $process.HasExited) {
            $script:Proxy=$proxy
            $script:NewBridgeProcess=$process
            $script:Bridge=[pscustomobject]@{proxy=$proxy;listenPort=$localPort;upstreamPort=$port;startupName=$null;startupValue=$null}
            return $true
        }
        try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null } } catch { }
        $process.Dispose()
    }
    return $false
}

function Set-BridgeStartup($State) {
    $run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $old=$State.bridge
    $item=Get-ItemProperty $run -ErrorAction SilentlyContinue
    $name=$null
    if ($old -and $old.startupName) {
        $property=if ($item) { $item.PSObject.Properties[[string]$old.startupName] } else { $null }
        if ($property -and $property.Value -ceq $old.startupValue) { $name=[string]$old.startupName }
    }
    if (-not $name) { $name='AntigravityProxyHelper-'+[guid]::NewGuid().ToString('N') }
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $file=Join-Path $script:Root 'launcher-src\SocksBridge.ps1'
    $command='"'+$ps+'" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$file+'" -UpstreamPort '+$script:Bridge.upstreamPort+' -ListenPort '+$script:Bridge.listenPort
    $script:Bridge | Add-Member -NotePropertyName startupName -NotePropertyValue $name -Force
    $script:Bridge | Add-Member -NotePropertyName startupValue -NotePropertyValue $command -Force
    $State | Add-Member -NotePropertyName bridge -NotePropertyValue $script:Bridge -Force
    Save-State $State
    New-Item -Path $run -Force | Out-Null
    New-ItemProperty -Path $run -Name $name -Value $command -PropertyType String -Force | Out-Null
    $script:BridgePersisted=$true
}

function Remove-BridgeStartup($State) {
    if (-not $State -or -not $State.bridge -or -not $State.bridge.startupName) { return }
    $run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $item=Get-ItemProperty $run -ErrorAction SilentlyContinue
    $property=if ($item) { $item.PSObject.Properties[[string]$State.bridge.startupName] } else { $null }
    if ($property -and $property.Value -ceq $State.bridge.startupValue) {
        Remove-ItemProperty -Path $run -Name $State.bridge.startupName -ErrorAction Stop
    }
    $State | Add-Member -NotePropertyName bridge -NotePropertyValue $null -Force
    Save-State $State
}

function Stop-OwnedBridges {
    foreach ($process in @(Get-OwnedBridgeProcesses)) {
        try { Stop-Process -Id $process.ProcessId -ErrorAction Stop } catch { }
    }
}

function Stop-NewBridgeIfUnused {
    if ($script:NewBridgeProcess -and -not $script:BridgePersisted) {
        try {
            if (-not $script:NewBridgeProcess.HasExited) { $script:NewBridgeProcess.Kill(); $script:NewBridgeProcess.WaitForExit(5000) | Out-Null }
        } catch { }
        $script:NewBridgeProcess.Dispose()
        $script:NewBridgeProcess=$null
    }
}
