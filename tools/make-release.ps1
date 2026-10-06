# Sestaví ZIP pro GitHub Release do složky dist/:
#   powershell -ExecutionPolicy Bypass -File tools/make-release.ps1
# V ZIPu je složka Sluzbak jen s tím, co aplikace potřebuje k běhu. Číslo verze se bere ze Sluzbak.ps1.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$root = Split-Path $PSScriptRoot
if ([IO.File]::ReadAllText((Join-Path $root 'Sluzbak.ps1')) -notmatch "\`$version = '([\d.]+)'") {
    throw 'Ve Sluzbak.ps1 chybí řádek s $version.'
}
$version = $Matches[1]

# Testy, nástroje a obrázky do README zůstávají jen v repozitáři.
$items = @('Sluzbak.ps1', 'Sluzbak.xaml', 'Golemio.ps1', 'Sluzbak.cmd', 'install.cmd',
    'README.md', 'CHANGELOG.md', 'LICENSE', 'assets\sluzbak.ico', 'demo') | Where-Object { Test-Path (Join-Path $root $_) }

$dist = Join-Path $root 'dist'
$null = New-Item -ItemType Directory -Force $dist
$zipPath = Join-Path $dist "Sluzbak-$version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }

$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($item in $items) {
        $source = Join-Path $root $item
        $files = if (Test-Path $source -PathType Container) { Get-ChildItem $source -File -Recurse | Sort-Object FullName } else { Get-Item $source }
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            # cmd.exe čte spolehlivě jen konce řádků CRLF a v pracovní kopii mohou být LF.
            if ($file.Extension -eq '.cmd') {
                $bytes = [Text.Encoding]::ASCII.GetBytes(([Text.Encoding]::ASCII.GetString($bytes) -replace "`r?`n", "`r`n"))
            }
            # V ZIPu patří do cest lomítka dopředu; se zpětnými si neporadí každý rozbalovací program.
            $name = 'Sluzbak/' + $file.FullName.Substring($root.Length + 1).Replace('\', '/')
            $stream = $zip.CreateEntry($name, 'Optimal').Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
    }
} finally { $zip.Dispose() }

"OK: dist/Sluzbak-$version.zip ($([Math]::Round((Get-Item $zipPath).Length / 1KB)) kB)"
