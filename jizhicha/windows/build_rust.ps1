[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CargoExecutable,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkspacePath
)

$ErrorActionPreference = 'Stop'

# Rust panic locations otherwise disclose the build machine's workspace and
# user profile. Cargo's encoded flag variable keeps paths containing spaces as
# single arguments; ASCII 31 is Cargo's documented separator.
$remapFlags = @(
    "--remap-path-prefix=$WorkspacePath=huse-vpn-next"
)
$userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
if (-not [string]::IsNullOrWhiteSpace($userHome)) {
    $remapFlags += "--remap-path-prefix=$userHome=user-home"
}
$env:CARGO_ENCODED_RUSTFLAGS = $remapFlags -join [char]31

& $CargoExecutable build `
    --manifest-path $ManifestPath `
    --package huse-vpn-ffi `
    --release
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
