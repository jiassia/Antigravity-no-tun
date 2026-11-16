function Test-AntigravityGuiProcess($Process, [string]$ExecutablePath) {
    return [bool]($Process -and $Process.Name -ieq 'Antigravity.exe' -and
        $Process.ExecutablePath -ieq $ExecutablePath -and $Process.CommandLine -and
        $Process.CommandLine -notmatch '(?:^|\s)--(?:type|import|require|eval|print)(?:=|\s|$)|sidecar_sdk[\\/]register_loader|(?:^|\s|["\\/])sidecars[\\/]')
}

function Get-AntigravityGuiProcesses([string]$ExecutablePath) {
    return @(Get-CimInstance Win32_Process | Where-Object { Test-AntigravityGuiProcess $_ $ExecutablePath })
}

function Read-GuiLocalJson([string]$Address) {
    $uri=[uri]$Address
    if (-not $uri.IsLoopback -or $uri.Scheme -ne 'http') { throw '只允许访问本机应用接口。' }
    $request=[Net.HttpWebRequest]::Create($uri)
    $request.Proxy=$null; $request.Timeout=3000; $request.ReadWriteTimeout=3000
    $response=$request.GetResponse()
    try {
        $reader=New-Object IO.StreamReader($response.GetResponseStream())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}

function Get-GuiDebuggerPages($Process) {
    $profile=Join-Path $env:APPDATA 'Antigravity'
    if ($Process.CommandLine -match '--user-data-dir(?:=|\s+)(?:"([^"]+)"|(\S+))') {
        $profile=$Matches[1]+$Matches[2]
    }
    $portPath=Join-Path $profile 'DevToolsActivePort'
    $ports=@()
    if (Test-Path -LiteralPath $portPath) {
        $value=Get-Content -LiteralPath $portPath -TotalCount 1
        if ($value -match '^\d+$') { $ports+=[int]$value }
    }
    $listeners=@(Get-NetTCPConnection -State Listen -OwningProcess $Process.ProcessId -ErrorAction SilentlyContinue)
    $ownedPorts=@($listeners | ForEach-Object { [int]$_.LocalPort } | Select-Object -Unique)
    $ports=@($ports | Where-Object { $_ -in $ownedPorts })
    $ports+=@($ownedPorts | Where-Object { $_ -notin $ports } | Select-Object -First 8)
    foreach ($port in $ports) {
        try {
            $pages=@(Read-GuiLocalJson ('http://127.0.0.1:'+$port+'/json/list'))
            $targets=@($pages | Where-Object {
                $_.type -eq 'page' -and $_.title -eq 'Antigravity' -and
                $_.url -match '^https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/' -and
                $_.webSocketDebuggerUrl -match '^ws://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/'
            })
            if ($targets.Count) { return $targets }
        } catch { }
    }
    return @()
}

function Invoke-GuiSessionJavaScript($Page, [string]$Expression) {
    if (-not ('AgyProxy.GuiSessionTransport' -as [type])) {
        Add-Type -Path (Join-Path $script:Root 'launcher-src\GuiSessionTransport.cs')
    }
    $request=@{id=1;method='Runtime.evaluate';params=@{
        expression=$Expression;awaitPromise=$true;returnByValue=$true
    }} | ConvertTo-Json -Depth 8 -Compress
    $raw=[AgyProxy.GuiSessionTransport]::Request($Page.webSocketDebuggerUrl,$request,15000)
    $result=$raw | ConvertFrom-Json
    if ($result.error -or $result.result.exceptionDetails) {
        $detail=$result.result.exceptionDetails.exception.description
        if (-not $detail) { $detail='应用未确认保存操作。' }
        throw $detail
    }
    return $result.result.result.value
}

function Save-AntigravityGuiSession($Process) {
    Write-Host '  正在保存 GUI 输入草稿并核对磁盘写入结果...'
    $pages=@(Get-GuiDebuggerPages $Process)
    if (-not $pages.Count) { throw '无法连接 GUI 保存接口，保留现有进程，避免丢失未保存内容。' }
    $expression=[IO.File]::ReadAllText((Join-Path $script:Root 'launcher-src\capture-gui-drafts.js'))
    $windows=@()
    foreach ($page in $pages) {
        $saved=Invoke-GuiSessionJavaScript $page $expression
        if (-not $saved.verified) { throw 'GUI 没有返回保存成功回执，保留现有进程。' }
        $windows+=@($saved)
    }
    $backupDir=Join-Path $script:StateDir 'gui-sessions'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $path=Join-Path $backupDir ((Get-Date -Format 'yyyyMMdd-HHmmssfff')+'-'+$Process.ProcessId+'.json')
    $snapshot=[pscustomobject]@{version=1;created=(Get-Date).ToString('o');processId=$Process.ProcessId;
        processCreated=$Process.CreationDate;windows=$windows;verified=$true}
    $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding UTF8
    $snapshot | Add-Member -NotePropertyName backupPath -NotePropertyValue $path
    Write-Host ('  已保存并核对 '+$windows.Count+' 个窗口，恢复副本：'+$path)
    return $snapshot
}

function Stop-AntigravityGuiForRestart($Process) {
    $saved=Save-AntigravityGuiSession $Process
    Write-Host '  保存已完成，正在正常退出 GUI...'
    $running=Get-Process -Id $Process.ProcessId -ErrorAction SilentlyContinue
    if ($running) {
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Process.ProcessId) -ErrorAction SilentlyContinue
        if (-not (Test-AntigravityGuiProcess $current $Process.ExecutablePath) -or $current.CreationDate -ne $Process.CreationDate) {
            throw 'GUI 进程身份发生变化，已停止退出操作。'
        }
        $closed=$running.CloseMainWindow()
        if ($closed -and $running.WaitForExit(15000)) { return $saved }
    } else { return $saved }
    # The captured chat drafts cannot prove that other editor files were saved.
    # Never force-close a window that may be waiting for a save decision.
    if (-not (Get-Process -Id $Process.ProcessId -ErrorAction SilentlyContinue)) { return $saved }
    throw ('GUI 未正常退出，已保留当前进程。请保存工作并关闭软件后重试；草稿副本：'+$saved.backupPath)
}

function Restore-AntigravityGuiSession($Snapshot, [string]$ExecutablePath) {
    if (-not $Snapshot) { return }
    Write-Host '  正在等待 GUI 就绪并恢复已保存的输入草稿...'
    $expression=[IO.File]::ReadAllText((Join-Path $script:Root 'launcher-src\restore-gui-drafts.js'))
    $savedWindows=ConvertTo-Json -InputObject @($Snapshot.windows) -Depth 20 -Compress
    $expression=$expression.Replace('__AGY_SAVED_WINDOWS__',$savedWindows)
    $route=$Snapshot.windows[0].route
    if ($route -notmatch '^/(?:c/[a-zA-Z0-9-]+)?(?:\?[^#]*)?$') { $route='/' }
    $routeJson=$route | ConvertTo-Json -Compress
    for ($attempt=0;$attempt -lt 20;$attempt++) {
        $processes=@(Get-AntigravityGuiProcesses $ExecutablePath)
        foreach ($process in $processes) {
            foreach ($page in @(Get-GuiDebuggerPages $process)) {
                try {
                    $navigation=Invoke-GuiSessionJavaScript $page ('(()=>{const route='+$routeJson+';if(location.pathname+location.search!==route){location.replace(location.origin+route);return {navigating:true}}return {navigating:false}})()')
                    if ($navigation.navigating) { continue }
                    $restored=Invoke-GuiSessionJavaScript $page $expression
                    if ($restored.restored -and $restored.editorVerified) {
                        Write-Host ('  GUI 已恢复，已载入 '+$restored.draftCount+' 项输入草稿。')
                        return
                    }
                } catch { }
            }
        }
        Start-Sleep -Milliseconds 750
    }
    throw ('软件已启动，草稿已保存，但尚未确认恢复。恢复副本：'+$Snapshot.backupPath)
}
