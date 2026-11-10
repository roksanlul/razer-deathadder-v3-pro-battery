param(
    [switch]$TestOnly
)

$ErrorActionPreference = 'Stop'

$zigCommand = Get-Command zig -ErrorAction Stop
$zig = $zigCommand.Source
$zigVersion = (& $zig version).Trim()
if ($zigVersion -ne '0.14.1') {
    throw "Zig 0.14.1 is required; found $zigVersion."
}

$buildDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("deathadder-v3pro-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $buildDirectory | Out-Null

try {
    $archive = Join-Path $buildDirectory 'hidapi-0.14.0.zip'
    $extractDirectory = Join-Path $buildDirectory 'source'
    $hidapiDirectory = Join-Path $extractDirectory 'hidapi-hidapi-0.14.0'
    $hidapiHeaderDirectory = Join-Path $hidapiDirectory 'hidapi'
    $hidapiWindowsDirectory = Join-Path $hidapiDirectory 'windows'
    $hidapiSource = Join-Path $hidapiWindowsDirectory 'hid.c'
    $hidapiObject = Join-Path $buildDirectory 'hidapi.obj'
    $appSource = Join-Path $PSScriptRoot 'windows_tray.zig'

    & curl.exe -L --fail --silent --show-error --output $archive `
        'https://github.com/libusb/hidapi/archive/refs/tags/hidapi-0.14.0.zip'
    if ($LASTEXITCODE -ne 0) {
        throw "Downloading HIDAPI failed with exit code $LASTEXITCODE."
    }

    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $expectedHash = '68217A595FFC517E7B88E7BFEDDDAEF0558CEB8A8937327ECC3DE2016CDF8CFC'
    if ($archiveHash -ne $expectedHash) {
        throw "HIDAPI archive SHA-256 mismatch: $archiveHash."
    }

    Expand-Archive -LiteralPath $archive -DestinationPath $extractDirectory
    if (!(Test-Path -LiteralPath $hidapiSource)) {
        throw "HIDAPI source was not found at $hidapiSource."
    }

    & $zig test -I $hidapiHeaderDirectory -target x86_64-windows-gnu `
        -lc -lgdi32 -luser32 -lshell32 $appSource
    if ($LASTEXITCODE -ne 0) {
        throw "Zig tests failed with exit code $LASTEXITCODE."
    }

    if ($TestOnly) {
        return
    }

    & $zig build-obj -target x86_64-windows-gnu -O ReleaseSafe `
        -I $hidapiHeaderDirectory -I $hidapiWindowsDirectory -lc `
        "-femit-bin=$hidapiObject" $hidapiSource
    if ($LASTEXITCODE -ne 0) {
        throw "Building HIDAPI failed with exit code $LASTEXITCODE."
    }

    $output = Join-Path $PSScriptRoot 'razer-battery-menu-tray.exe'
    & $zig build-exe -I $hidapiHeaderDirectory -O ReleaseSafe `
        -target x86_64-windows-gnu --subsystem windows `
        "-femit-bin=$output" -lc -luser32 -lshell32 -lgdi32 $appSource $hidapiObject
    if ($LASTEXITCODE -ne 0) {
        throw "Building the tray application failed with exit code $LASTEXITCODE."
    }

    Write-Output "Built $output"
}
finally {
    Remove-Item -LiteralPath $buildDirectory -Recurse -Force
}
