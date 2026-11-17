# User-level WinINet proxy settings. The enclosing launcher provides Save-State.
function Open-WindowsProxyKey([bool]$Writable, [bool]$Create) {
    $path='Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($Create) { return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path) }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$Writable)
}

function Read-WindowsProxyValue([string]$Name) {
    $key=Open-WindowsProxyKey $false $false
    if (-not $key) { return [pscustomobject]@{exists=$false;kind=$null;value=$null} }
    try {
        if ($key.GetValueNames() -notcontains $Name) {
            return [pscustomobject]@{exists=$false;kind=$null;value=$null}
        }
        $kind=$key.GetValueKind($Name)
        $raw=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $value=switch ([string]$kind) {
            'String'       { [string]$raw }
            'ExpandString' { [string]$raw }
            'DWord'        { [int]$raw }
            'QWord'        { [long]$raw }
            'MultiString'  { ,([string[]]$raw) }
            'Binary'       { [Convert]::ToBase64String([byte[]]$raw) }
            'None'         { [Convert]::ToBase64String([byte[]]$raw) }
            default        { throw "Cannot preserve registry value type '$kind' for $Name." }
        }
        return [pscustomobject]@{exists=$true;kind=[string]$kind;value=$value}
    } finally { $key.Dispose() }
}

function Write-WindowsProxyValue([string]$Name, $Snapshot) {
    if (-not $Snapshot.exists) {
        $key=Open-WindowsProxyKey $true $false
        if (-not $key) { return }
        try { $key.DeleteValue($Name,$false) } finally { $key.Dispose() }
        return
    }
    $kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$Snapshot.kind)
    $value=switch ([string]$kind) {
        'String'       { [string]$Snapshot.value }
        'ExpandString' { [string]$Snapshot.value }
        'DWord'        { [int]$Snapshot.value }
        'QWord'        { [long]$Snapshot.value }
        'MultiString'  { ,([string[]]@($Snapshot.value)) }
        'Binary'       { ,([Convert]::FromBase64String([string]$Snapshot.value)) }
        'None'         { ,([Convert]::FromBase64String([string]$Snapshot.value)) }
        default        { throw "Cannot restore registry value type '$kind' for $Name." }
    }
    $key=Open-WindowsProxyKey $true $true
    if (-not $key) { throw 'Unable to open the current user Internet Settings registry key.' }
    try { $key.SetValue($Name,$value,$kind) } finally { $key.Dispose() }
}

function Read-WindowsProxyPair {
    return [pscustomobject]@{server=(Read-WindowsProxyValue 'ProxyServer');enable=(Read-WindowsProxyValue 'ProxyEnable')}
}

function Test-WindowsProxyValueEqual($Left, $Right) {
    if ($null -eq $Left -or $null -eq $Right -or [bool]$Left.exists -ne [bool]$Right.exists) { return $false }
    if (-not $Left.exists) { return $true }
    if ([string]$Left.kind -cne [string]$Right.kind) { return $false }
    if ([string]$Left.kind -eq 'MultiString') {
        $a=@($Left.value); $b=@($Right.value)
        if ($a.Count -ne $b.Count) { return $false }
        for ($i=0; $i -lt $a.Count; $i++) { if ([string]$a[$i] -cne [string]$b[$i]) { return $false } }
        return $true
    }
    return ([string]$Left.value -ceq [string]$Right.value)
}

function Test-WindowsProxyPairEqual($Left, $Right) {
    return ((Test-WindowsProxyValueEqual $Left.server $Right.server) -and (Test-WindowsProxyValueEqual $Left.enable $Right.enable))
}

function ConvertTo-WindowsProxyEndpoint([string]$Address, [bool]$RequireScheme) {
    if ([string]::IsNullOrWhiteSpace($Address)) { return $null }
    $text=$Address.Trim()
    if ($RequireScheme -and $text -notmatch '^http://') { return $null }
    if ($text -notmatch '^(?i)(?:http://)?(?<host>localhost|127\.0\.0\.1|\[::1\]):(?<port>[0-9]{1,5})/?$') { return $null }
    $port=0
    if (-not [int]::TryParse($Matches.port,[ref]$port) -or $port -lt 1 -or $port -gt 65535) { return $null }
    $hostName=$Matches.host.ToLowerInvariant()
    return [pscustomobject]@{host=$hostName;port=$port;authority=($hostName+':'+$port)}
}

function Test-WindowsProxyEndpoint([string]$Address, $Wanted) {
    $candidate=ConvertTo-WindowsProxyEndpoint $Address $false
    if (-not $candidate -or $candidate.port -ne $Wanted.port) { return $false }
    # IPv4 loopback and localhost are accepted interchangeably; IPv6 remains separate.
    if ($candidate.host -eq '[::1]' -or $Wanted.host -eq '[::1]') { return $candidate.host -eq $Wanted.host }
    return $true
}

function Test-WindowsProxyAlreadySet($Pair, $Wanted) {
    if (-not $Pair.enable.exists -or $Pair.enable.kind -ne 'DWord' -or [int]$Pair.enable.value -ne 1 -or
        -not $Pair.server.exists -or $Pair.server.kind -ne 'String') { return $false }
    $text=[string]$Pair.server.value
    if ($text -notmatch '=') { return (Test-WindowsProxyEndpoint $text $Wanted) }
    $http=$null; $https=$null
    foreach ($part in $text.Split([char]';')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        if ($part -notmatch '^\s*([a-zA-Z]+)\s*=\s*(\S+)\s*$') { return $false }
        $name=$Matches[1].ToLowerInvariant(); $value=$Matches[2]
        if ($name -eq 'http') {
            if ($null -ne $http) { return $false }; $http=$value
        } elseif ($name -eq 'https') {
            if ($null -ne $https) { return $false }; $https=$value
        }
    }
    return ($null -ne $http -and $null -ne $https -and
        (Test-WindowsProxyEndpoint $http $Wanted) -and (Test-WindowsProxyEndpoint $https $Wanted))
}

function Notify-WindowsProxyChanged {
    if (-not ('AgyProxy.WinInetNotice' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace AgyProxy {
    public static class WinInetNotice {
        [DllImport("wininet.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int length);
    }
}
'@
    }
    foreach ($option in @(39,37)) {
        if (-not [AgyProxy.WinInetNotice]::InternetSetOption([IntPtr]::Zero,$option,[IntPtr]::Zero,0)) {
            $errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object ComponentModel.Win32Exception($errorCode))
        }
    }
}

# A transition writes the server first, then the enable flag. Its journal records
# both endpoints before either write, so an interrupted transition can be resumed.
function Test-WindowsProxyTransitionState($Current, $From, $To) {
    $middle=[pscustomobject]@{server=$To.server;enable=$From.enable}
    return ((Test-WindowsProxyPairEqual $Current $From) -or
        (Test-WindowsProxyPairEqual $Current $middle) -or (Test-WindowsProxyPairEqual $Current $To))
}

function Invoke-WindowsProxyTransition($From, $To) {
    $current=Read-WindowsProxyPair
    if (-not (Test-WindowsProxyTransitionState $current $From $To)) {
        throw 'Windows proxy settings changed while the operation was in progress.'
    }
    $middle=[pscustomobject]@{server=$To.server;enable=$From.enable}
    $changed=$false
    if (Test-WindowsProxyPairEqual $current $From) {
        if (-not (Test-WindowsProxyValueEqual $current.server $To.server)) {
            Write-WindowsProxyValue 'ProxyServer' $To.server
            $changed=$true
        }
        $current=Read-WindowsProxyPair
        if (-not (Test-WindowsProxyPairEqual $current $middle)) {
            throw 'Windows proxy settings changed while the server was being updated.'
        }
    }
    if (Test-WindowsProxyPairEqual $current $middle) {
        if (-not (Test-WindowsProxyValueEqual $current.enable $To.enable)) {
            Write-WindowsProxyValue 'ProxyEnable' $To.enable
            $changed=$true
        }
        $current=Read-WindowsProxyPair
    }
    if (-not (Test-WindowsProxyPairEqual $current $To)) {
        throw 'Windows proxy settings changed while the enable flag was being updated.'
    }
    return $changed
}

function Complete-WindowsProxyPending($State) {
    $record=$State.windowsProxy
    $pending=$record.pending
    if (-not $pending) { return }
    if ($pending.kind -notin @('set','restore','rollback-set','rollback-restore')) {
        throw 'The Windows proxy recovery record is invalid.'
    }
    $current=Read-WindowsProxyPair
    if (-not (Test-WindowsProxyTransitionState $current $pending.from $pending.to)) {
        throw 'Windows proxy settings changed after an interrupted operation; current settings were preserved.'
    }
    if ($pending.kind -eq 'set') {
        # An interrupted set is undone to its pre-operation state.
        $previous=$pending
        $pending=[pscustomobject]@{kind='rollback-set';from=$current;to=$pending.from}
        $record.pending=$pending
        try { Save-State $State } catch { $record.pending=$previous; throw }
    }
    $changed=Invoke-WindowsProxyTransition $pending.from $pending.to
    # A prior process may have changed values before it exited, even if this
    # invocation only finishes the journal, so refresh unconditionally here.
    Notify-WindowsProxyChanged
    if ($pending.kind -eq 'restore' -or ($pending.kind -eq 'rollback-set' -and -not $record.last)) {
        $State.windowsProxy=$null
    } else {
        $record.pending=$null
    }
    try { Save-State $State } catch {
        $State.windowsProxy=$record
        $record.pending=$pending
        throw
    }
}

function Invoke-WindowsProxyJournal($State, [string]$Kind, $From, $To) {
    $record=$State.windowsProxy
    $previousLast=$record.last
    $pending=[pscustomobject]@{kind=$Kind;from=$From;to=$To}
    $record.pending=$pending
    try { Save-State $State } catch {
        $record.pending=$null
        if ($Kind -eq 'set' -and -not $previousLast) { $State.windowsProxy=$null }
        throw
    }
    try {
        $changed=Invoke-WindowsProxyTransition $From $To
        if ($changed) { Notify-WindowsProxyChanged }
        if ($Kind -eq 'set') {
            $record.last=$To
            $record.pending=$null
        } else {
            $State.windowsProxy=$null
        }
        Save-State $State
        return $changed
    } catch {
        $failure=$_
        # The journal must remain durable before any rollback writes occur.
        $State.windowsProxy=$record
        $record.last=$previousLast
        $record.pending=$pending
        try {
            $current=Read-WindowsProxyPair
            if (-not (Test-WindowsProxyTransitionState $current $From $To)) {
                throw 'Windows proxy settings were changed by another process; current settings were preserved.'
            }
            if (Test-WindowsProxyPairEqual $current $From) {
                $record.pending=$null
                if ($Kind -eq 'set' -and -not $record.last) { $State.windowsProxy=$null }
                try { Save-State $State } catch {
                    $State.windowsProxy=$record
                    $record.pending=$pending
                    throw
                }
            } else {
                $rollbackKind=if ($Kind -eq 'set') { 'rollback-set' } else { 'rollback-restore' }
                $record.pending=[pscustomobject]@{kind=$rollbackKind;from=$current;to=$From}
                try { Save-State $State } catch { $record.pending=$pending; throw }
                Complete-WindowsProxyPending $State
            }
        } catch {
            throw ("Windows proxy operation failed: $($failure.Exception.Message). Recovery is pending: $($_.Exception.Message)")
        }
        throw $failure
    }
}

function Set-WindowsProxy([string]$Proxy, $State) {
    if (-not $State) { throw 'A saved state is required to manage the Windows proxy.' }
    $wanted=ConvertTo-WindowsProxyEndpoint $Proxy $true
    if (-not $wanted) { throw 'The Windows proxy must be a local HTTP address with an explicit port.' }
    if ($State.windowsProxy -and $State.windowsProxy.pending) { Complete-WindowsProxyPending $State }
    $current=Read-WindowsProxyPair
    if (Test-WindowsProxyAlreadySet $current $wanted) { return $false }
    if (-not $State.windowsProxy) {
        $record=[pscustomobject]@{version=1;original=$current;last=$null;pending=$null}
        $State | Add-Member -NotePropertyName windowsProxy -NotePropertyValue $record -Force
    } elseif ($State.windowsProxy.last -and -not (Test-WindowsProxyPairEqual $current $State.windowsProxy.last)) {
        # A user or another application changed the setting between runs.
        # Make that later choice the baseline before this launch changes it again.
        $State.windowsProxy.original=$current
    }
    $target=[pscustomobject]@{
        server=[pscustomobject]@{exists=$true;kind='String';value=$wanted.authority}
        enable=[pscustomobject]@{exists=$true;kind='DWord';value=1}
    }
    return (Invoke-WindowsProxyJournal $State 'set' $current $target)
}

function Restore-WindowsProxy($State) {
    if (-not $State -or -not $State.windowsProxy) { return $false }
    if ($State.windowsProxy.pending) { Complete-WindowsProxyPending $State }
    $record=$State.windowsProxy
    if (-not $record -or -not $record.last) { return $false }
    $current=Read-WindowsProxyPair
    if (-not (Test-WindowsProxyPairEqual $current $record.last)) { return $false }
    return (Invoke-WindowsProxyJournal $State 'restore' $current $record.original)
}
