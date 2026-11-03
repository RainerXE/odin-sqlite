# Build the static SQLite library that sqlite3.odin's named foreign import
# links on Windows:
#
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
#
# Produces artifacts\sqlite3.lib. Needs the MSVC toolchain (Visual Studio Build
# Tools with the C++ workload). The static CRT (/MT) is deliberate: Odin links
# the static CRT, so a /MD object would fail to link with LNK4098/LNK2019.
$ErrorActionPreference = 'Stop'

$PkgDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Art = Join-Path $PkgDir 'artifacts'
$Src = Join-Path $PkgDir 'amalgamation\sqlite3.c'

if (!(Test-Path $Src)) {
    throw "amalgamation\sqlite3.c not found; see amalgamation\README.md"
}

$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if ($null -eq $cl) {
    # cl.exe is only on PATH inside a developer prompt; locate the toolchain and
    # initialise it for this process via vcvars64.bat.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (!(Test-Path $vswhere)) {
        throw "MSVC not found: install Visual Studio Build Tools with the C++ workload"
    }
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (!$vsPath) {
        throw "MSVC not found: no Visual Studio installation with the C++ toolchain"
    }
    $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (!(Test-Path $vcvars)) {
        throw "vcvars64.bat not found at $vcvars"
    }
    # Persist the developer environment into this PowerShell process.
    $envDump = & cmd /c "`"$vcvars`" >nul 2>&1 && set"
    foreach ($line in $envDump) {
        if ($line -match '^([^=]+)=(.*)$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
        }
    }
}

New-Item -ItemType Directory -Force $Art | Out-Null

& cl /nologo /c /O2 /MT `
    /DSQLITE_THREADSAFE=1 /DSQLITE_ENABLE_FTS5 /DSQLITE_ENABLE_RTREE `
    "$Src" /Fo"$Art\sqlite3.obj"
if ($LASTEXITCODE -ne 0) { throw "compiling the SQLite amalgamation failed" }

& lib /nologo /OUT:"$Art\sqlite3.lib" "$Art\sqlite3.obj"
if ($LASTEXITCODE -ne 0) { throw "creating sqlite3.lib failed" }

Write-Host "Built $Art\sqlite3.lib"
