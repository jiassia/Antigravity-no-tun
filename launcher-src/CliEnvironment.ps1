# Persist only the CLI directory added by this launcher, retaining the raw PATH.
function Get-CliRegistryPath([string]$Scope) {
    if ($Scope -eq 'User') {
        $root=[Microsoft.Win32.Registry]::CurrentUser
        $subkey='Environment'
    } elseif ($Scope -eq 'Machine') {
        $root=[Microsoft.Win32.Registry]::LocalMachine
        $subkey='SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    } else { throw "Unknown PATH scope: $Scope" }

    $key=$root.OpenSubKey($subkey,$false)
    if (-not $key) { return [pscustomobject]@{exists=$false;value='';kind=$null} }
    try {
        if ($key.GetValueNames() -notcontains 'Path') {
            return [pscustomobject]@{exists=$false;value='';kind=$null}
        }
        $kind=$key.GetValueKind('Path')
        if ($kind -notin @([Microsoft.Win32.RegistryValueKind]::String,[Microsoft.Win32.RegistryValueKind]::ExpandString)) {
            throw "Unsupported $Scope PATH registry value type: $kind"
        }
        $raw=$key.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject]@{exists=$true;value=[string]$raw;kind=$kind}
    } finally { $key.Dispose() }
}

function Set-CliUserRegistryPath([string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind) {
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    if (-not $key) { throw 'Unable to open the user environment registry key.' }
    try { $key.SetValue('Path',$Value,$Kind) } finally { $key.Dispose() }
}

function Remove-CliUserRegistryPath {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    if (-not $key) { return }
    try { $key.DeleteValue('Path',$false) } finally { $key.Dispose() }
}

function ConvertTo-CliComparablePath([string]$Value, [bool]$ExpandVariables) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $value=$Value.Trim()
    if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length-1] -eq '"') {
        $value=$value.Substring(1,$value.Length-2)
    }
    if ($ExpandVariables) { $value=[Environment]::ExpandEnvironmentVariables($value) }
    $value=$value.Replace('/','\')
    if ($value -match '^[a-zA-Z]:\\+$') { return $value.Substring(0,2)+'\' }
    return $value.TrimEnd([char]'\')
}

function Test-CliPathContains([string]$Value, [string]$Directory, [bool]$ExpandVariables) {
    $wanted=ConvertTo-CliComparablePath $Directory $false
    foreach ($part in $Value.Split([char]';')) {
        $candidate=ConvertTo-CliComparablePath $part $ExpandVariables
        if ($candidate -and [string]::Equals($candidate,$wanted,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Ensure-CliPath([string]$CliPath, $State) {
    if ([string]::IsNullOrWhiteSpace($CliPath)) { return $false }
    $item=Get-Item -LiteralPath $CliPath -ErrorAction Stop
    if ($item.PSIsContainer) { throw "CLI path is not a file: $CliPath" }
    if ($item.Name -notin @('agy.exe','agy.cmd','agy.bat')) { return $false }
    if (-not $State) { throw 'A saved state is required to manage the CLI PATH.' }
    $directory=[IO.Path]::GetDirectoryName($item.FullName)
    if ($directory.Contains(';')) { throw "CLI directory cannot be represented in PATH: $directory" }

    $userPath=Get-CliRegistryPath 'User'
    $machinePath=Get-CliRegistryPath 'Machine'
    $processPath=[string][Environment]::GetEnvironmentVariable('Path','Process')
    if (-not (Test-CliPathContains $processPath $directory $false)) {
        $newProcessPath=if ($processPath.Length) { $processPath+';'+$directory } else { $directory }
        [Environment]::SetEnvironmentVariable('Path',$newProcessPath,'Process')
    }
    if ((Test-CliPathContains $userPath.value $directory ($userPath.kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString)) -or
        (Test-CliPathContains $machinePath.value $directory ($machinePath.kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString))) {
        return $false
    }

    $entries=@()
    $existing=$State.PSObject.Properties['cliPathAddedEntries']
    if ($existing -and $null -ne $existing.Value) { $entries=@($existing.Value | Where-Object { $_ }) }
    if (-not $entries.Count) {
        $State | Add-Member -NotePropertyName cliPathOriginalValueExisted -NotePropertyValue ([bool]$userPath.exists) -Force
    }
    if (-not ($entries | Where-Object { [string]::Equals([string]$_,$directory,[StringComparison]::Ordinal) })) {
        $entries=@($entries)+@($directory)
    }
    $State | Add-Member -NotePropertyName cliPathAddedEntries -NotePropertyValue $entries -Force
    Save-State $State

    $newUserPath=if ($userPath.value.Length) { $userPath.value+';'+$directory } else { $directory }
    $kind=if ($userPath.exists) { $userPath.kind } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
    Set-CliUserRegistryPath $newUserPath $kind
    return $true
}

function Restore-CliPath($State) {
    if (-not $State) { return $false }
    $property=$State.PSObject.Properties['cliPathAddedEntries']
    if (-not $property -or $null -eq $property.Value) { return $false }
    $entries=@($property.Value | Where-Object { $_ })
    if (-not $entries.Count) { return $false }

    $userPath=Get-CliRegistryPath 'User'
    $changed=$false
    if ($userPath.exists) {
        $parts=New-Object 'System.Collections.Generic.List[string]'
        $parts.AddRange([string[]]$userPath.value.Split([char]';'))
        foreach ($entry in $entries) {
            for ($index=0; $index -lt $parts.Count; $index++) {
                if ([string]::Equals($parts[$index],[string]$entry,[StringComparison]::Ordinal)) {
                    $parts.RemoveAt($index)
                    $changed=$true
                    break
                }
            }
        }
        if ($changed) {
            if ($parts.Count -eq 0 -and -not $State.cliPathOriginalValueExisted) {
                Remove-CliUserRegistryPath
            } else {
                Set-CliUserRegistryPath ([string]::Join(';',$parts.ToArray())) $userPath.kind
            }
        }
    }
    $State | Add-Member -NotePropertyName cliPathAddedEntries -NotePropertyValue @() -Force
    Save-State $State
    return $changed
}
