# Zkouška naživo: načte všechny karty ze skutečného Golemio API a vypíše, co která dostala.
#   powershell -ExecutionPolicy Bypass -File tests/live.ps1
#
# Klíč a místo si bere z nastavení aplikace (%APPDATA%\GolemWatch\settings.json), takže aplikaci nejdřív
# jednou spusť a nastav. Klíč se nikam nevypisuje. Když karta selže na zpracování odpovědi, vypíše se
# i místo v kódu, kde se to stalo; to je přesně to, co je potřeba k opravě.
param([string]$SettingsPath = (Join-Path $env:APPDATA 'GolemWatch\settings.json'))

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'Golemio.ps1')

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    "Nastavení $SettingsPath neexistuje. Spusť nejdřív aplikaci a zadej klíč a místo."
    exit 2
}
try {
    $saved = [IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $token = [Net.NetworkCredential]::new('', (ConvertTo-SecureString $saved.token)).Password
} catch {
    'Nastavení se nepodařilo přečíst. Klíč jde rozšifrovat jen pod účtem, který ho uložil.'
    exit 2
}

$context = @{ Token = $token; Demo = $null; Limiter = New-Object System.Collections.Queue; Cache = @{} }
$latitude = [double]$saved.latitude
$longitude = [double]$saved.longitude
$district = try { Get-District $context $latitude $longitude } catch { '' }
"Místo: $($saved.place) ($(Format-LatLng $latitude $longitude))$(if ($district) { ", $district" })"

# Kolik položek karta ukáže; podle toho je vidět, jestli data opravdu dorazila.
$counts = [ordered]@{
    Transit = { param($d) "$(@($d.Departures).Count) odjezdů, $(@($d.Stops).Count) nástupišť, $(@($d.Infotexts).Count) mimořádností" }
    Vehicles = { param($d) "$(@($d.Items).Count) vozidel, z toho $(@($d.Items | Where-Object { $_.Headsign }).Count) s cílem: " + (@($d.Items | ForEach-Object { "$($_.Route) $($_.Distance)" }) -join ', ') }
    Alerts = { param($d) "$(@($d.Items).Count) ukázaných$(if ($d.More) { ", $($d.More)" })" }
    Parking = { param($d) "$(@($d.Items).Count) parkovišť, z toho $(@($d.Items | Where-Object { $_.Capacity -like 'volných*' }).Count) s obsazeností$(if ($d.Machine) { ', automat v dosahu' })" }
    Cars = { param($d) "$(@($d.Items).Count) aut: " + (@($d.Items | ForEach-Object { "$($_.Name) $($_.Distance)" }) -join ', ') }
    Cycling = { param($d) "$($d.Total) $($d.Caption), $(@($d.Items).Count) směrů" }
    Waste = { param($d) "$(@($d.Stations).Count) stanovišť, $(@($d.Bulky).Count) velkoobjemových" + $(if ($d.BulkyNote) { " ($($d.BulkyNote))" }) }
    Nearby = { param($d) "$(@($d.Items).Count) míst: " + (@($d.Items | ForEach-Object { "$($_.Kind) $($_.Distance)" }) -join ', ') }
    Air = { param($d) "$($d.Index), $(@($d.Components).Count) látek, $($d.Updated)" }
    Microclimate = { param($d) "$(@($d.Values).Count) veličin, $($d.Updated)" }
}

$failed = 0
foreach ($name in $counts.Keys) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $data = if ($name -eq 'Transit') { & "Get-$name" $context $latitude $longitude $null } else { & "Get-$name" $context $latitude $longitude }
        $what = if ($data.Empty) { "PRÁZDNO: $($data.Empty)" } else { & $counts[$name] $data }
        'ok    {0,-13} {1,5} ms  {2} | {3}' -f $name, $watch.ElapsedMilliseconds, $data.Meta, $what
    } catch {
        $failed++
        $kind = [string]$_.Exception.Data['Kind']
        'CHYBA {0,-13} {1,5} ms  {2}' -f $name, $watch.ElapsedMilliseconds, $(if ($kind) { "$kind`: $($_.Exception.Message)" } else { $_.Exception.Message })
        # Chyba bez druhu není ze sítě, ale z našeho zpracování odpovědi.
        if (-not $kind) { $_.ScriptStackTrace -split "`n" | Select-Object -First 4 | ForEach-Object { "        $_" } }
    }
}
"---"; "chyb: $failed"
exit $failed
