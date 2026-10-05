# Testy datové vrstvy (Golemio.ps1) nad ukázkovými daty ze složky demo. Nevolají síť.
#   powershell -ExecutionPolicy Bypass -File tests/unit.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'Golemio.ps1')

# Formátování nesmí záviset na nastavení počítače; česká kultura odhalí desetinné čárky tam, kde nemají být.
[Threading.Thread]::CurrentThread.CurrentCulture = 'cs-CZ'

$script:fail = 0
function Check($what, $actual, $expected) {
    if ("$actual" -ceq "$expected") { "ok    $what = $actual" }
    else { $script:fail++; "FAIL  $what = '$actual' (čekáno '$expected')" }
}
function CheckMatch($what, $actual, $pattern) {
    if ("$actual" -match $pattern) { "ok    $what = $actual" }
    else { $script:fail++; "FAIL  $what = '$actual' (čekán vzor '$pattern')" }
}
function ErrorKind([scriptblock]$action) {
    try { $null = & $action; '<bez chyby>' } catch { [string]$_.Exception.Data['Kind'] }
}

$demo = @{ Token = ''; Demo = Join-Path $root 'demo' }
$lat = 50.0753; $lng = 14.4379   # náměstí Míru

'--- dotazy a formátování'
Check 'dotaz' (Format-Query ([ordered]@{ latlng = '50.0755,14.4378'; range = 300; limit = $null; 'ids[]' = 'U1 Z', 'U2'; flag = $true; half = 1.5 })) `
    '?latlng=50.0755%2C14.4378&range=300&ids%5B%5D=U1%20Z&ids%5B%5D=U2&flag=true&half=1.5'
Check 'prázdný dotaz' (Format-Query @{}) ''
Check 'souřadnice s tečkou' (Format-LatLng 50.0755 14.43781234) '50.0755,14.437812'
Check 'stupeň šířky v metrech' ([Math]::Round((Get-Distance 50 14 51 14))) 111195
Check 'vzdálenost pod 1 km' (Format-Distance 123) '120 m'
Check 'vzdálenost těsně pod 1 km' (Format-Distance 994) '990 m'
Check 'vzdálenost nad 1 km' (Format-Distance 1234) '1,2 km'
CheckMatch 'bounding box' (Get-BoundingBox $lat $lng 1500) '^50\.08\d+,14\.41\d+,50\.06\d+,14\.45\d+$'
Check 'číslo česky' (Format-Number 38.44) '38,4'
Check 'vzorec NO2' (Format-Formula 'NO2') "NO$([char]0x2082)"
Check 'vzorec PM2_5' (Format-Formula 'PM2_5') 'PM2,5'

'--- poloha'
$position = Read-Position @(14.4, 50.1)
Check 'bod' "$($position.Latitude) $($position.Longitude)" '50.1 14.4'
Check 'bod zabalený navíc (příklad ze specifikace)' (Read-Position @(, @(14.4, 50.1))).Latitude 50.1
Check 'polygon: první vrchol' (Read-Position @(, @(@(14.4, 50.1), @(14.5, 50.2)))).Longitude 14.4
Check 'prázdná pozice' ($null -eq (Read-Position @())) $true
Check 'pozice mimo planetu' ($null -eq (Read-Position @(14.4, 950))) $true
Check 'chybějící pozice' ($null -eq (Read-Position $null)) $true

'--- čas'
$today = (Get-PragueNow).Date
Check 'dnes' (Format-Day $today) 'dnes'
Check 'zítra' (Format-Day $today.AddDays(1)) 'zítra'
CheckMatch 'jiný den' (Format-Day $today.AddDays(3)) '^(po|út|st|čt|pá|so|ne) \d{1,2}\. \d{1,2}\.$'
Check 'datum bez času' (ConvertTo-Day '2026-10-07').ToString('yyyy-MM-dd') '2026-10-07'
Check 'UTC na pražský čas' (Format-Clock (ConvertTo-PragueTime '2026-07-01T07:05:00.000Z')) '9:05'
Check 'nesmyslný čas' ($null -eq (ConvertTo-PragueTime 'string')) $true

'--- chyby'
Check '401' (ConvertTo-ApiError 401).Data['Kind'] 'Unauthorized'
Check '403' (ConvertTo-ApiError 403).Data['Kind'] 'Forbidden'
Check '404' (ConvertTo-ApiError 404).Data['Kind'] 'NotFound'
Check '429' (ConvertTo-ApiError 429).Data['Kind'] 'RateLimited'
Check '500' (ConvertTo-ApiError 500).Data['Kind'] 'Unexpected'
Check 'chybějící ukázkový soubor' (ErrorKind { Invoke-Api $demo '/v9/neexistuje' }) 'NotFound'

'--- svoz odpadu'
$waste = Get-Waste $demo $lat $lng
Check 'stanoviště' $waste.Stations.Count 2
Check 'nejbližší stanoviště' $waste.Stations[0].Name 'Náměstí Míru 820/9'
CheckMatch 'vzdálenost stanoviště' $waste.Stations[0].Distance '^\d+ m$'
Check 'druhy seřazené, papír jen jednou' (($waste.Stations[0].Kinds | ForEach-Object Type) -join ', ') 'Barevné sklo, Nápojové kartóny, Papír, Plast'
$paper = $waste.Stations[0].Kinds | Where-Object Type -eq 'Papír'
Check 'papír: dny svozu' $paper.PickDays 'Po, St, Pá'
Check 'papír: další svoz' $paper.Next 'zítra'
Check 'papír: plnější z obou kontejnerů' $paper.Fill '62 %'
Check 'papír: barva' $paper.Color '#3B82F6'
Check 'plast: svoz dnes' ($waste.Stations[0].Kinds | Where-Object Type -eq 'Plast').Next 'dnes'
Check 'sklo bez senzoru nemá zaplněnost' ($waste.Stations[0].Kinds | Where-Object Type -eq 'Barevné sklo').Fill ''
Check 'velkoobjemové: daleký vynechán' $waste.Bulky.Count 2
CheckMatch 'velkoobjemové: kdy' $waste.Bulky[0].When '^(po|út|st|čt|pá|so|ne) \d{1,2}\. \d{1,2}\. · 14:00–18:00$'
Check 'velkoobjemové: kde' $waste.Bulky[0].Street 'Budečská × Francouzská'
Check 'velkoobjemové: bez poznámky' $waste.BulkyNote ''
Check 'odpad: není prázdno' $waste.Empty ''

'--- ovzduší'
$air = Get-Air $demo $lat $lng
CheckMatch 'stanice' $air.Meta '^Praha 2-Legerova · \d+ m$'
Check 'index' $air.Index 'Přijatelná'
Check 'barva indexu' "$($air.IndexColor) $($air.IndexTextColor)" '#00CC00 #000000'
Check 'složky bez prázdné hodnoty' $air.Components.Count 5
Check 'složky v pořadí' (($air.Components | ForEach-Object { "$($_.Code)/$($_.Hours)" }) -join ' ') 'NO2/1 O3/1 PM10/1 PM10/24 PM2_5/1'
Check 'NO2: hodnota' $air.Components[0].Value '38,4 µg/m³'
Check 'NO2: popis' $air.Components[0].Description 'oxid dusičitý'
Check 'PM10 za den' $air.Components[3].Period 'průměr za 24 h'
CheckMatch 'čas měření' $air.Updated '^měřeno (dnes|zítra|\S+ \d+\. \d+\.) v \d{1,2}:\d\d$'

'--- mikroklima'
$micro = Get-Microclimate $demo $lat $lng
CheckMatch 'senzor' $micro.Meta '^Náměstí Jiřího z Poděbrad · \d+ m$'
Check 'veličiny' $micro.Values.Count 5
Check 'teplota: poslední měření' ($micro.Values | Where-Object Name -eq 'Teplota vzduchu').Value '14,2 °C'
Check 'srážky: nula není prázdno' ($micro.Values | Where-Object Name -eq 'Srážky').Value '0 mm'
CheckMatch 'mikroklima: čas' $micro.Updated '^měřeno v \d{1,2}:\d\d$'

'--- parkování'
$parking = Get-Parking $demo $lat $lng
Check 'parkoviště podle vzdálenosti' (($parking.Items | ForEach-Object Name) -join ' | ') `
    'Garáže Vinohradská tržnice | Sokolská 1605/66, Praha 2 | Parkoviště Grébovka | Parkoviště Hlavní nádraží'
$garage = $parking.Items[0]
Check 'volná místa' "$($garage.Free) $($garage.Capacity)" '47 volných z 180'
Check 'volno je zelené' $garage.FreeColor '#7BD88F'
Check 'režim má přednost před typem' $garage.Kind 'Placené'
Check 'režim a vzdálenost na jednom řádku' $garage.Detail 'Placené · 520 m'
Check 'bez obsazenosti jen kapacita' "$($parking.Items[1].Free)|$($parking.Items[1].Capacity)|$($parking.Items[1].Kind)" '64|míst celkem|Pro zákazníky'
Check 'kapacita je šedá, ne zelená' $parking.Items[1].FreeColor '#8C93A8'
Check 'bez režimu se ukáže typ' "$($parking.Items[2].Kind)|$($parking.Items[2].Capacity)" 'Parkoviště|'
Check 'plno je červené' "$($parking.Items[3].Free) $($parking.Items[3].FreeColor)" '0 #FF8A80'

'--- MHD'
$stops = @(Find-Stops $demo $lat $lng)
Check 'nástupiště do 600 m, bez stanice a bez polohy' (($stops | ForEach-Object Id | Sort-Object) -join ' ') 'U476Z101P U476Z102P U476Z1P U476Z2P U689Z1P'
Check 'nejbližší první' ($stops[0].Meters -le $stops[-1].Meters) $true
$transit = Get-Transit $demo $lat $lng $null
Check 'zastávky v záhlaví' $transit.Meta 'Náměstí Míru, Šumavská'
Check 'odjezdy' $transit.Departures.Count 9
$first = $transit.Departures[0]
Check 'metro ve stanici' "$($first.Route) $($first.In) $($first.Color) $($first.Delay)|" 'A teď #00A562 |'
Check 'metro: kam a odkud' "$($first.Headsign) / $($first.Stop)" 'Depo Hostivař / Náměstí Míru · 1'
Check 'písmo na barvě linky' $first.RouteTextColor '#FFFFFF'
$tram = $transit.Departures[1]
Check 'tramvaj se zpožděním' "$($tram.Route) $($tram.In) $($tram.Delay) $($tram.Color)" '22 za 3 min +2 min #7A0603'
CheckMatch 'tramvaj: čas' $tram.Time '^\d{1,2}:\d\d$'
Check 'autobus bez sledování nemá zpoždění' "$($transit.Departures[3].Route) $($transit.Departures[3].Delay)|" '135 |'
$canceled = $transit.Departures[4]
Check 'zrušený spoj' "$($canceled.In) $($canceled.InColor) $($canceled.Opacity.ToString([Globalization.CultureInfo]::InvariantCulture))" 'zrušeno #FF8A80 0.55'
Check 'zastávka mimo seznam nástupišť' $transit.Departures[6].Stop 'Šumavská · A'
Check 'infotext' $transit.Infotexts.Count 1
Check 'zastávky se vrací pro příští obnovení' $transit.Stops.Count 5
$nowhere = Get-Transit $demo 49.0 13.0 $null
Check 'daleko od Prahy: hláška' $nowhere.Empty 'Do 600 metrů žádná zastávka PID není.'
Check 'daleko od Prahy: nic' $nowhere.Departures.Count 0

'--- v okolí'
$nearby = Get-Nearby $demo $lat $lng
Check 'od každého druhu jedno místo' (($nearby.Items | ForEach-Object Kind) -join ' | ') 'Lékárna | Knihovna | Úřad | Městská policie | Sběrný dvůr'
$pharmacy = $nearby.Items[0]
Check 'nejbližší lékárna, ne první v odpovědi' "$($pharmacy.Name) / $($pharmacy.Address)" 'Lékárna U Ludmily / Jugoslávská 620/29'
Check 'nonstop' "$($pharmacy.Status) $($pharmacy.StatusColor)" 'otevřeno nonstop #7BD88F'
CheckMatch 'vzdálenost' $pharmacy.Distance '^\d+ m$'
CheckMatch 'knihovna: stav podle otevírací doby' $nearby.Items[1].Status '^(otevřeno do \d{1,2}:\d\d|otevírá (zítra |[a-zčú]{2} )?v \d{1,2}:\d\d)$'
Check 'úřad: ulice z celé adresy' $nearby.Items[2].Address 'náměstí Míru 600/20'
$police = $nearby.Items[3]
Check 'policie: místo jména adresa' "$($police.Name) / $($police.Address) / $($police.Status)|" 'Lublaňská 1729/21 / Vinohrady / |'
Check 'sběrný dvůr: otevírací doba textem' "$($nearby.Items[4].Hours) / $($nearby.Items[4].Status)|" 'Po–Pá 8:30–18:00 (v zimě do 17:00), So 8:30–15:00 / |'

'--- otevírací doba'
# 5. 10. 2026 je pondělí.
function At([int]$day, [int]$hour, [int]$minute) { [DateTimeOffset]::new(2026, 10, $day, $hour, $minute, 0, [TimeSpan]::FromHours(2)) }
$office = @(
    @{ day_of_week = 'Monday'; opens = '08:00'; closes = '12:00' }
    @{ day_of_week = 'Monday'; opens = '13:00'; closes = '17:30' }
    @{ day_of_week = 'Wednesday'; opens = '08:00'; closes = '12:00' }
)
$open = Get-OpenStatus $office (At 5 10 30)
Check 'otevřeno' "$($open.Text) $($open.Open)" 'otevřeno do 12:00 True'
$pause = Get-OpenStatus $office (At 5 12 0)
Check 'polední pauza' "$($pause.Text) $($pause.Open)" 'otevírá v 13:00 False'
Check 'večer: další úřední den je středa' (Get-OpenStatus $office (At 5 18 0)).Text 'otevírá st v 8:00'
Check 'den předem' (Get-OpenStatus $office (At 6 9 0)).Text 'otevírá zítra v 8:00'
Check 'bez otevírací doby nic' ($null -eq (Get-OpenStatus $null (At 5 10 0))) $true
Check 'nečitelné časy nic' ($null -eq (Get-OpenStatus @(@{ day_of_week = 'Monday'; opens = 'dle domluvy'; closes = '' }) (At 5 10 0))) $true
Check 'do půlnoci' (Get-OpenStatus @(@{ day_of_week = 'Monday'; opens = '18:00'; closes = '00:00' }) (At 5 23 30)).Text 'otevřeno do 24:00'
$library = @(
    @{ day_of_week = 'Monday'; opens = '00:00'; closes = '23:59'; type = 'self_service'; is_default = $true }
    @{ day_of_week = 'Monday'; opens = '13:00'; closes = '19:00'; type = 'standard'; is_default = $true }
)
Check 'samoobsluha se nepočítá' (Get-OpenStatus $library (At 5 10 0)).Text 'otevírá v 13:00'
$holiday = $library + @{
    day_of_week = 'Monday'; opens = '09:00'; closes = '11:00'; type = 'standard'; is_default = $false
    valid_from = '2026-10-04T22:00:00.000Z'; valid_through = '2026-10-11T21:59:59.000Z'
}
Check 'mimořádná doba má přednost' (Get-OpenStatus $holiday (At 5 10 0)).Text 'otevřeno do 11:00'
Check 'po skončení platnosti zase běžná' (Get-OpenStatus $holiday (At 12 14 0)).Text 'otevřeno do 19:00'

'--- limit API'
$queue = New-Object System.Collections.Queue
1..17 | ForEach-Object { $queue.Enqueue([DateTime]::UtcNow) }
$watch = [Diagnostics.Stopwatch]::StartNew()
Wait-RateLimit $queue
Check 'pod limitem se nečeká' ($watch.ElapsedMilliseconds -lt 200) $true
Check 'dotaz se zapíše do fronty' $queue.Count 18
$queue.Clear()
$queue.Enqueue([DateTime]::UtcNow.AddSeconds(-7.6))
1..17 | ForEach-Object { $queue.Enqueue([DateTime]::UtcNow) }
$watch.Restart()
Wait-RateLimit $queue
Check 'plné okno počká, až nejstarší dotaz vypadne' ($watch.ElapsedMilliseconds -ge 250 -and $watch.ElapsedMilliseconds -lt 3000) $true
Check 've frontě zůstává jen posledních 8 sekund' $queue.Count 18
Wait-RateLimit $null
Check 'bez fronty se nic nehlídá' $true $true

'--- nastavení'
$found = @(Find-Address $demo 'náměstí Míru')
Check 'nalezené adresy' $found.Count 3
Check 'první adresa' "$($found[0].Name.Split(',')[0]) $($found[0].Latitude) $($found[0].Longitude)" 'Náměstí Míru 50.0753 14.4379'
Check 'ověření klíče' (Test-Token $demo) $true

'--- místa, kde si specifikace API protiřečí'
$quirks = Join-Path ([IO.Path]::GetTempPath()) "golemwatch-test-$PID"
Copy-Item $demo.Demo $quirks -Recurse
try {
    $alt = @{ Token = ''; Demo = $quirks }
    $utf8 = New-Object Text.UTF8Encoding $false

    # Index ovzduší jako číslo (tak ho uvádí specifikace) se páruje podle id.
    $text = [IO.File]::ReadAllText("$quirks\v2-airqualitystations.json") -replace '"AQ_hourly_index": "1B"', '"AQ_hourly_index": 2'
    [IO.File]::WriteAllText("$quirks\v2-airqualitystations.json", $text, $utf8)
    Check 'index jako číslo' (Get-Air $alt $lat $lng).Index 'Přijatelná'

    # Neznámý index se ukáže aspoň kódem.
    [IO.File]::WriteAllText("$quirks\v2-airqualitystations.json", ($text -replace '"AQ_hourly_index": 2', '"AQ_hourly_index": "9Z"'), $utf8)
    Check 'neznámý index' (Get-Air $alt $lat $lng).Index 'Index 9Z'

    # Body mikroklimatu jako jeden objekt místo seznamu, název v point_name.
    [IO.File]::WriteAllText("$quirks\v2-microclimate-points.json",
        '{"point_id": 207, "location_id": 200, "point_name": "Jediný bod", "lat": 50.0779, "lng": 14.45, "measures": []}', $utf8)
    $single = Get-Microclimate $alt $lat $lng
    CheckMatch 'jeden bod místo seznamu' $single.Meta '^Jediný bod · \d+ m$'
    Check 'bez číselníku veličin zůstane kód' ($single.Values | Where-Object Name -eq 'air_temp200').Value '14,2 °C'

    # Pozice stanoviště zabalená do pole navíc, přesně jako v příkladu ze specifikace.
    $text = [IO.File]::ReadAllText("$quirks\v2-sortedwastestations.json") -replace '"coordinates": \[14\.4386, 50\.0758\]', '"coordinates": [[14.4386, 50.0758]]'
    [IO.File]::WriteAllText("$quirks\v2-sortedwastestations.json", $text, $utf8)
    Check 'zabalená pozice stanoviště' (Get-Waste $alt $lat $lng).Stations[0].Name 'Náměstí Míru 820/9'

    # Když velkoobjemový odpad selže, tříděný se ukáže i tak.
    Remove-Item "$quirks\v1-bulky-waste-stations.json"
    $partial = Get-Waste $alt $lat $lng
    Check 'bez velkoobjemového: stanoviště zůstávají' $partial.Stations.Count 2
    CheckMatch 'bez velkoobjemového: poznámka' $partial.BulkyNote 'chybí'

    # Bez číselníků ovzduší se ukážou holé kódy.
    Remove-Item "$quirks\v2-airqualitystations-componenttypes.json"
    $global:GolemWatchCache = @{}
    $bare = Get-Air $alt $lat $lng
    Check 'bez číselníku: hodnota bez jednotky' $bare.Components[0].Value '38,4'
} finally {
    Remove-Item $quirks -Recurse -Force
}

'--- kódování souborů'
# Windows PowerShell čte skript bez BOM jako ANSI a rozbije češtinu.
foreach ($file in Get-ChildItem $root -Recurse -Filter *.ps1) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $isAscii = -not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1)
    Check "$($file.Name): UTF-8 s BOM" ($hasBom -or $isAscii) $true
}

"---"; "chyb: $script:fail"
exit $script:fail
