param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int] $UpstreamPort,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int] $ListenPort
)

$ErrorActionPreference = 'Stop'

try {
    Add-Type -Path (Join-Path $PSScriptRoot 'SocksBridge.cs')
    [Antigravity.Proxy.SocksBridge]::Run($UpstreamPort, $ListenPort)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
