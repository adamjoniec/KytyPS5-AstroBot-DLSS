param(
    [ValidateRange(1, 256)][int]$Jobs = [Math]::Min(8, [Environment]::ProcessorCount),
    [string]$March = 'native'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$build = Join-Path $repo '_Build\windows-optimized'
$install = Join-Path $build 'install'
$toolRoot = Join-Path $repo '_Build\tools'
$source = 'C:\kyty-src19'
$backup = $null
$mapped = $false

function Run([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited with code $LASTEXITCODE" }
}

function RequireFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file missing: $Path" }
    return $Path
}

try {
    Set-Location -LiteralPath $repo
    $vswhere = RequireFile "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'Install the Visual Studio C++ x64 build tools and Windows SDK.' }
    # Import the SDK/library environment into this process, without changing the caller's shell.
    $devcmd = RequireFile "$vs\Common7\Tools\VsDevCmd.bat"
    $vsEnv = & $env:ComSpec /d /c "call `"$devcmd`" -no_logo -arch=x64 -host_arch=x64 >nul && set"
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the Visual Studio build environment.' }
    foreach ($line in $vsEnv) {
        if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
    }
    $cmake = Join-Path $toolRoot 'cmake\bin\cmake.exe'
    if (-not (Test-Path -LiteralPath $cmake)) { $cmake = "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" }
    $cmake = RequireFile $cmake
    $ninja = Join-Path $toolRoot 'ninja\ninja.exe'
    if (-not (Test-Path -LiteralPath $ninja)) { $ninja = "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe" }
    $ninja = RequireFile $ninja
    $clang = Get-ChildItem -LiteralPath "$toolRoot\llvm22" -Filter clang-cl.exe -File -Recurse | Select-Object -First 1
    if (-not $clang) { throw "LLVM 22.1.3 is required under $toolRoot\llvm22" }
    $llvm = $clang.DirectoryName
    $version = & $clang.FullName --version
    if ($LASTEXITCODE -ne 0 -or ($version -join "`n") -notmatch 'clang version 22\.1\.3\b') { throw 'The checked-in PGO profile requires LLVM 22.1.3.' }
    $qt = Join-Path $toolRoot 'Qt\6.10.3\msvc2022_64'
    $null = RequireFile "$qt\lib\cmake\Qt6\Qt6Config.cmake"
    $null = RequireFile "$toolRoot\glslang\bin\glslang.exe"
    $null = RequireFile "$repo\tools\pgo\u59-int21-1.profdata"
    $null = RequireFile "$llvm\lld-link.exe"
    $null = RequireFile "$llvm\llvm-lib.exe"
    $env:PATH = "$llvm;$(Split-Path $cmake);$(Split-Path $ninja);$qt\bin;$toolRoot\glslang\bin;$toolRoot\python\Scripts;$env:PATH"
    $env:CL = ''
    $env:_CL_ = ''

    Run git @('submodule', 'update', '--init', '--recursive', '--jobs', "$Jobs")
    $sdk = Join-Path $repo '_Build\deps\streamline\sdk'
    if (-not (Test-Path -LiteralPath "$sdk\include\sl.h")) {
        $slSource = Join-Path $repo '_Build\streamline-src'
        if (-not (Test-Path -LiteralPath "$slSource\.git")) {
            Run git @('clone', '--depth', '1', '--branch', 'v2.14.1', '--filter=blob:none', '--sparse', 'https://github.com/NVIDIA-RTX/Streamline.git', $slSource)
        }
        Run git @('-C', $slSource, 'sparse-checkout', 'set', 'include')
        New-Item -ItemType Directory -Force -Path $sdk | Out-Null
        Copy-Item -LiteralPath "$slSource\include" -Destination $sdk -Recurse -Force
    }
    $null = RequireFile "$sdk\include\sl.h"

    # PGO anonymous-namespace symbols depend on this exact source path. Preserve any
    # existing junction, including a dangling one; never replace a normal directory.
    $existing = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType -ne 'Junction') { throw "$source exists and is not a junction." }
    $sameTarget = $existing -and ([IO.Path]::GetFullPath([string]$existing.Target[0]).TrimEnd('\') -ieq $repo.TrimEnd('\'))
    if (-not $sameTarget) {
        if ($existing) {
            $backup = "$source.build-backup-$([Guid]::NewGuid().ToString('N'))"
            Rename-Item -LiteralPath $source -NewName (Split-Path -Leaf $backup)
        }
        New-Item -ItemType Junction -Path $source -Target $repo | Out-Null
        $mapped = $true
    }
    New-Item -ItemType Directory -Force -Path $build | Out-Null
    Write-Host "Building Release: Astro Bot int21 PGO, emulator LTO, diagnostics OFF, -march=$March ($Jobs jobs)."
    Write-Host "MSVC tools $env:VCToolsVersion; LLVM: $($version[0])"
    Run $cmake @('-S', $source, '-B', $build, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release', '-DKYTY_EMULATOR_IPO=ON', '-DKYTY_CP_DIAGNOSTICS=OFF',
        "-DKYTY_MARCH=$March", '-DKYTY_PGO_GENERATE=OFF',
        '-DKYTY_PGO_USE=C:/kyty-src19/tools/pgo/u59-int21-1.profdata',
        '-DKYTY_BUILD_ORIGIN=Fork', '-DKYTY_BUILD_REPOSITORY=adamjoniec/KytyPS5-AstroBot-DLSS',
        "-DCMAKE_C_COMPILER=$llvm/clang-cl.exe", "-DCMAKE_CXX_COMPILER=$llvm/clang-cl.exe",
        "-DCMAKE_LINKER=$llvm/lld-link.exe", "-DCMAKE_AR=$llvm/llvm-lib.exe",
        "-DCMAKE_MAKE_PROGRAM=$ninja", "-DCMAKE_PREFIX_PATH=$qt", "-DKYTY_STREAMLINE_SDK=$sdk")
    if (-not (Get-Content -LiteralPath "$build\build.ninja" -Raw).Contains('C$:\kyty-src19\src\emulator.cpp')) {
        throw 'The Ninja source path differs from the PGO training path.'
    }
    Run $cmake @('--build', $build, '--target', 'launcher', 'kyty_emulator', 'astro_taa_geometry_tests', 'astro_dlss_output_tests', '--parallel', "$Jobs")
    Run "$build\astro_taa_geometry_tests.exe" @()
    Run "$build\astro_dlss_output_tests.exe" @()
    Run $cmake @('--install', $build, '--prefix', $install)
    Copy-Item -LiteralPath "$repo\tools\u59-preset.json", "$repo\LICENSE" -Destination $install -Force
    Copy-Item -LiteralPath "$repo\docs\ASTRO-BOT-DLSSG.md" -Destination "$install\README-DLSSG.md" -Force
    Copy-Item -LiteralPath "$repo\docs\ASTRO-BOT-DLSS-SR.md" -Destination "$install\README-DLSS-SR.md" -Force
    $fonts = Join-Path $install '3rdparty\tracy\profiler\src\font'
    New-Item -ItemType Directory -Force -Path $fonts | Out-Null
    Copy-Item -Path "$repo\3rdparty\tracy\profiler\src\font\Roboto-*.ttf" -Destination $fonts -Force
    Copy-Item -LiteralPath "$repo\3rdparty\SPIRV-Tools\LICENSE" -Destination "$fonts\LICENSE-Apache-2.0.txt" -Force
    Write-Host "Optimized runtime: $install"
    Write-Host 'DLSS needs the Streamline v2.14.1 runtime DLLs in the streamline subfolder; see README-DLSSG.md.'
} finally {
    if ($mapped) {
        $link = Get-Item -LiteralPath $source -Force
        if ($source -ne 'C:\kyty-src19' -or $link.LinkType -ne 'Junction' -or
            [IO.Path]::GetFullPath([string]$link.Target[0]).TrimEnd('\') -ine $repo.TrimEnd('\')) {
            throw "Refusing to remove unexpected source junction: $source. Original junction backup: $backup"
        }
        # Nonrecursive removal of the junction itself; its target is never deleted.
        [IO.Directory]::Delete($source)
    }
    if ($backup) { Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $source) }
}
