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
Check 'druhy podle nejbližšího svozu, papír jen jednou' (($waste.Stations[0].Kinds | ForEach-Object Type) -join ', ') 'Plasty a nápojové kartony, Papír, Kovy, Barevné sklo'
$paper = $waste.Stations[0].Kinds | Where-Object Type -eq 'Papír'
Check 'papír: dny svozu' $paper.PickDays 'Po, St, Pá'
Check 'papír: další svoz' $paper.Next 'zítra'
Check 'papír: plnější z obou kontejnerů' $paper.Fill '62 %'
Check 'papír: barva' $paper.Color '#3B82F6'
# "Multikomoditní sběr" z API je žlutý kontejner na plasty a nápojové kartony, ne směsný odpad.
$yellow = $waste.Stations[0].Kinds | Where-Object Type -eq 'Plasty a nápojové kartony'
Check 'multikomoditní sběr: svoz dnes' $yellow.Next 'dnes'
Check 'multikomoditní sběr: žlutá jako plast' "$($yellow.Color) $($wasteColors[6])" '#F5C542 #F5C542'
Check 'barvy kontejnerů: sklo zelené a bílé, kovy šedé, oleje fialové' (($waste.Stations.Kinds | Where-Object { $_.Type -in 'Barevné sklo', 'Čiré sklo', 'Kovy', 'Jedlé tuky a oleje' } | Sort-Object Type | ForEach-Object Color) -join ' ') '#3FA34D #E8EAF0 #B48EF2 #A3A9B8'
Check 'sklo bez senzoru nemá zaplněnost' ($waste.Stations[0].Kinds | Where-Object Type -eq 'Barevné sklo').Fill ''
Check 'velkoobjemové: daleký vynechán' $waste.Bulky.Count 2
CheckMatch 'velkoobjemové: kdy' $waste.Bulky[0].When '^(po|út|st|čt|pá|so|ne) \d{1,2}\. \d{1,2}\. · 14:00–18:00$'
Check 'velkoobjemové: kde' $waste.Bulky[0].Street 'Budečská × Francouzská'
Check 'velkoobjemové: bez poznámky' $waste.BulkyNote ''
Check 'odpad: není prázdno' $waste.Empty ''

'--- ovzduší'
# Seznam stanic má v ukázce (stejně jako naživo) měsíce staré měření; platná čísla jsou v historii.
$air = Get-Air $demo $lat $lng
CheckMatch 'stanice' $air.Meta '^Praha 2-Legerova · \d+ m$'
Check 'index z nejnovějšího řádku historie' $air.Index 'Přijatelná'
Check 'barva indexu' "$($air.IndexColor) $($air.IndexTextColor)" '#FFF200 #000000'
Check 'složky bez prázdné hodnoty' $air.Components.Count 5
Check 'složky v pořadí' (($air.Components | ForEach-Object { "$($_.Code)/$($_.Hours)" }) -join ' ') 'NO2/1 O3/1 PM10/1 PM10/24 PM2_5/1'
Check 'NO2: hodnota' $air.Components[0].Value '38,4 µg/m³'
Check 'NO2: popis' $air.Components[0].Description 'oxid dusičitý'
Check 'PM10 za den' $air.Components[3].Period 'průměr za 24 h'
Check 'PM10 za den na jeden řádek' $air.Components[3].Detail 'částice PM10 · 24 h'
CheckMatch 'čas měření' $air.Updated '^měřeno (dnes|zítra|\S+ \d+\. \d+\.) v \d{1,2}:\d\d$'

'--- mikroklima'
$micro = Get-Microclimate $demo $lat $lng
CheckMatch 'senzor: nejbližší, který má data' $micro.Meta '^Náměstí Jiřího z Poděbrad · \d+ m$'
Check 'veličiny: z každé jedna, v pořadí karty' (($micro.Values | ForEach-Object Name) -join ', ') 'Teplota, Vlhkost, Tlak, Vítr, Nárazy větru, Směr větru, Srážky, UV index'
Check 'teplota: poslední měření, ze dvou metrů' ($micro.Values | Where-Object Name -eq 'Teplota').Value '14,2 °C'
Check 'tlak v hektopascalech' ($micro.Values | Where-Object Name -eq 'Tlak').Value '1016 hPa'
Check 'vítr zaokrouhlený' ($micro.Values | Where-Object Name -eq 'Vítr').Value '9,3 km/h'
Check 'směr větru slovem' ($micro.Values | Where-Object Name -eq 'Směr větru').Value 'JZ'
Check 'srážky: nula není prázdno' ($micro.Values | Where-Object Name -eq 'Srážky').Value '0 mm'
Check 'veličina mimo seznam má jméno z číselníku' ($micro.Values | Where-Object Name -eq 'UV index').Value '2'
CheckMatch 'mikroklima: čas' $micro.Updated '^měřeno v \d{1,2}:\d\d$'

'--- parkování'
$parking = Get-Parking $demo $lat $lng
Check 'parkoviště podle vzdálenosti' (($parking.Items | ForEach-Object Name) -join ' | ') `
    'Garáže Vinohradská tržnice | Sokolská 1605/66, Praha 2 | Parkoviště Grébovka | Parkoviště Hlavní nádraží'
$garage = $parking.Items[0]
Check 'volná místa' "$($garage.Free) $($garage.Capacity)" '47 volných z 180'
Check 'volno je zelené' $garage.FreeColor '#7BD88F'
Check 'režim má přednost před typem' $garage.Kind 'Placené'
Check 'vzdálenost a režim na jednom řádku' $garage.Detail '520 m · Placené'
Check 'bez obsazenosti jen kapacita' "$($parking.Items[1].Free)|$($parking.Items[1].Capacity)|$($parking.Items[1].Kind)" '64|míst|Pro zákazníky'
Check 'kapacita je šedá, ne zelená' $parking.Items[1].FreeColor '#8C93A8'
Check 'bez režimu se ukáže typ' "$($parking.Items[2].Kind)|$($parking.Items[2].Capacity)" 'Parkoviště|'
Check 'plno je červené' "$($parking.Items[3].Free) $($parking.Items[3].FreeColor)" '0 #FF8A80'
Check 'nejbližší parkovací automat' $parking.Machine 'Nejbližší parkovací automat 190 m'

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
Check 'daleko od Prahy: hláška' $nowhere.Empty 'Do 600 m žádná zastávka PID není.'
Check 'daleko od Prahy: nic' $nowhere.Departures.Count 0

'--- vozidla v okolí'
Check 'světové strany' ((0, 44, 90, 135, 200, 225, 265, 315, 359, -90 | ForEach-Object { Format-Compass $_ }) -join ' ') 'S SV V JV J JZ Z SZ S Z'
Check 'bez azimutu nic' "$(Format-Compass $null)|$(Format-Compass '')|" '||'
$vehicles = Get-Vehicles $demo $lat $lng
Check 'vozidla do kilometru, bez vzdálenější tramvaje' $vehicles.Meta '4 do 1 km'
Check 'vozidla od nejbližšího' (($vehicles.Items | ForEach-Object Route) -join ' ') 'A 22 135 16'
$metro = $vehicles.Items[0]
Check 'metro: barva linky, cíl ze spoje' "$($metro.Color) $($metro.Headsign) / $($metro.State) / $($metro.Delay)|" '#00A562 Depo Hostivař / v zastávce / |'
$moving = $vehicles.Items[1]
Check 'tramvaj na trati: směr a zpoždění z vteřin' "$($moving.Color) $($moving.Headsign) / $($moving.State) / $($moving.Delay)" '#7A0603 Bílá Hora / směr Z / +2 min'
Check 'zpoždění pod půl minuty se neukazuje' "$($vehicles.Items[2].Color) $($vehicles.Items[2].Delay)|" '#007DA8 |'
CheckMatch 'vozidlo: vzdálenost' $moving.Distance '^\d+ m$'
Check 'nikde nic nejede' (Get-Vehicles $demo 49.0 13.0).Empty 'Do 1 km teď žádný spoj MHD nejede.'

'--- mimořádnosti'
$alerts = Get-Alerts $demo $lat $lng
Check 'mimořádnosti' "$($alerts.Meta) / $($alerts.Items.Count)$($alerts.More)" '3 v celé síti / 3'
Check 'nejdřív nejzávažnější' (($alerts.Items | ForEach-Object { $_.Text.Split(' ')[0] }) -join ' ') 'Metro Provoz Mezi'
Check 'zastávky jednou a nejvýš tři' $alerts.Items[0].Stops 'Pražského povstání, Pankrác, Budějovická a další'
Check 'dvě nástupiště téže zastávky' $alerts.Items[1].Stops 'Smíchovské nádraží, Lihovar'
Check 'konec platnosti' "$($alerts.Items[0].Until) / $($alerts.Items[2].Until)" 'do zítra / dnes končí'
CheckMatch 'konec za dva týdny datem' $alerts.Items[1].Until '^do (po|út|st|čt|pá|so|ne) \d{1,2}\. \d{1,2}\.$'
Check 'závažná je červená, ostatní oranžové' "$($alerts.Items[0].Color) $($alerts.Items[1].Color)" '#FF8A80 #E9A45B'

'--- sdílená auta'
$cars = Get-Cars $demo $lat $lng
Check 'auta do 1,5 km' $cars.Meta '3 do 1,5 km'
Check 'auta od nejbližšího, značka jen jednou' (($cars.Items | ForEach-Object Name) -join ' | ') 'Škoda Fabia | Škoda Enyaq | Toyota Yaris Cross'
Check 'auto: provozovatel, palivo, dostupnost' $cars.Items[2].Detail 'Anytime · hybrid · ihned'
CheckMatch 'auto: vzdálenost' $cars.Items[0].Distance '^\d+ m$'

'--- cyklosčítač'
$cycling = Get-Cycling $demo $lat $lng
Check 'bližší sčítač hlásí nuly, bere se další' $cycling.Meta 'Podolské nábřeží · 2,5 km'
Check 'součet obou směrů' ($cycling.Total -replace '\s') '2801'
Check 'trasa v popisku' $cycling.Caption 'kol od půlnoci · trasa A 2'
Check 'směry' (($cycling.Items | ForEach-Object { "$($_.Name) $($_.Value -replace '(?<=\d)\s(?=\d)')" }) -join ' | ') 'směr centrum 1412 | směr Braník 1389 · pěších 257'

'--- městská část'
Check 'bod uvnitř obrysu' (Test-InRing @(@(0, 0), @(4, 0), @(4, 4), @(0, 4)) 2 2) $true
Check 'bod vedle obrysu' (Test-InRing @(@(0, 0), @(4, 0), @(4, 4), @(0, 4)) 2 5) $false
Check 'městská část místa, ne první v odpovědi' (Get-District $demo $lat $lng) 'Praha 2'
Check 'mimo Prahu nic' "$(Get-District $demo 49.0 13.0)|" '|'

'--- volby uživatele'
$tight = @{ Token = ''; Demo = $demo.Demo; Options = @{ StopsRange = 300; WasteRange = 100; ParkingRange = 600; Departures = 4 } }
Check 'bez voleb platí výchozí' "$(Get-Option $demo 'StopsRange') $(Get-Option $demo 'Departures')" '600 12'
Check 'volba z nastavení' (Get-Option $tight 'StopsRange') 300
Check 'co ve volbách chybí, má výchozí hodnotu' (Get-Option $tight 'Refresh') 30
Check 'užší okruh zastávek' ((@(Find-Stops $tight $lat $lng) | ForEach-Object Id | Sort-Object) -join ' ') 'U476Z101P U476Z102P U476Z1P U476Z2P'
$fewer = Get-Transit $tight $lat $lng $null
Check 'užší okruh: zastávky v záhlaví' $fewer.Meta 'Náměstí Míru'
Check 'počet odjezdů' $fewer.Departures.Count 4
Check 'užší okruh odpadu' ((Get-Waste $tight $lat $lng).Stations | ForEach-Object Name) 'Náměstí Míru 820/9'
$closer = Get-Parking $tight $lat $lng
Check 'užší okruh parkování' "$($closer.Items.Count) parkoviště $($closer.Meta)" '2 parkoviště do 600 m'
$strict = @{ Token = ''; Demo = $demo.Demo; Options = @{ StopsRange = 30; WasteRange = 50; ParkingRange = 200 } }
Check 'nic v okruhu: zastávky' (Get-Transit $strict $lat $lng $null).Empty 'Do 30 m žádná zastávka PID není.'
Check 'nic v okruhu: odpad' (Get-Waste $strict $lat $lng).Empty 'Do 50 m žádné stanoviště tříděného odpadu není.'
Check 'nic v okruhu: parkování' (Get-Parking $strict $lat $lng).Empty 'Do 200 m žádné parkoviště není.'

'--- v okolí'
$nearby = Get-Nearby $demo $lat $lng
Check 'od každého druhu jedno místo' (($nearby.Items | ForEach-Object Kind) -join ' | ') 'Lékárna | Nemocnice | Knihovna | Úřad | Městská policie | Sběrný dvůr | Hřiště | Zahrada'
$pharmacy = $nearby.Items[0]
Check 'nejbližší lékárna, ne první v odpovědi' "$($pharmacy.Name) / $($pharmacy.Address)" 'Lékárna U Ludmily / Jugoslávská 620/29'
Check 'nonstop' "$($pharmacy.Status) $($pharmacy.StatusColor)" 'otevřeno nonstop #7BD88F'
CheckMatch 'vzdálenost' $pharmacy.Distance '^\d+ m$'
Check 'nemocnice: nejbližší nemocnice, ne bližší ordinace' "$($nearby.Items[1].Name) / $($nearby.Items[1].Distance)" 'Všeobecná fakultní nemocnice v Praze / 1,1 km'
CheckMatch 'knihovna: stav podle otevírací doby' $nearby.Items[2].Status '^(otevřeno do \d{1,2}:\d\d|otevírá (zítra |[a-zčú]{2} )?v \d{1,2}:\d\d)$'
Check 'úřad: ulice z celé adresy' $nearby.Items[3].Address 'náměstí Míru 600/20'
$police = $nearby.Items[4]
Check 'policie: místo jména adresa' "$($police.Name) / $($police.Address) / $($police.Status)|" 'Lublaňská 1729/21 / Vinohrady / |'
Check 'sběrný dvůr: otevírací doba textem' "$($nearby.Items[5].Hours) / $($nearby.Items[5].Status)|" 'Po–Pá 8:30–18:00 (v zimě do 17:00), So 8:30–15:00 / |'
Check 'hřiště: nejbližší a jeho vybavení' "$($nearby.Items[6].Name) / $($nearby.Items[6].Hours)" 'Riegrovy sady - Na Smetance / Plocha pro míčové hry, Voda-hydrant nebo umyvadlo'
Check 'zahrada: otevírací doba z vlastností' "$($nearby.Items[7].Name) / $($nearby.Items[7].Hours)" 'Riegrovy sady / Celoročně volný přístup'
Check 'podrobnosti do bubliny' $nearby.Items[7].Detail "Riegrovy sady`nRiegrovy sady 28`nCeloročně volný přístup"

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

'--- paměť odpovědí'
# Síť tu zastupuje počítadlo: je vidět, kolikrát se pro odpověď opravdu šlo ven.
$script:calls = New-Object System.Collections.ArrayList
$script:reject = 0
function Invoke-Http([string]$uri, [string]$token, [string]$service) {
    $null = $script:calls.Add($uri)
    if ($script:reject -gt 0) { $script:reject--; throw (ConvertTo-ApiError 429) }
    if ($uri -match '/forbidden') { throw (ConvertTo-ApiError 403) }
    if ($uri -match '/vehiclepositions') { return Read-Demo $demo.Demo '/v2/public/vehiclepositions' }
    if ($uri -match '/gtfs/trips/([^?]+)') { return @{ trip_headsign = "cíl $($Matches[1])" } }
    @{ n = $script:calls.Count }
}
# Zestárne všechno, co v paměti je, o daný počet sekund.
function Age($memory, [double]$seconds) { foreach ($key in @($memory.Keys)) { $memory[$key].At = $memory[$key].At.AddSeconds(-$seconds) } }

$memory = @{}
$net = @{ Token = 'x'; Demo = $null; Cache = $memory }
$null = Invoke-Api $net '/v2/x' ([ordered]@{ a = 1 })
$again = Invoke-Api $net '/v2/x' ([ordered]@{ a = 1 })
Check 'stejný dotaz podruhé jde z paměti' "$($script:calls.Count) $($again.n)" '1 1'
$null = Invoke-Api $net '/v2/x' ([ordered]@{ a = 2 })
Check 'jiný dotaz jde na síť' $script:calls.Count 2
Age $memory 599
$null = Invoke-Api $net '/v2/x' ([ordered]@{ a = 1 })
Check 'těsně před deseti minutami pořád z paměti' $script:calls.Count 2
Age $memory 2
$fresh = Invoke-Api $net '/v2/x' ([ordered]@{ a = 1 })
Check 'po deseti minutách znovu na síť' "$($script:calls.Count) $($fresh.n)" '3 3'
Check 'prošlé odpovědi se uklízejí' $memory.Count 1

$null = Invoke-Api $net '/v2/live' @{} $cacheLive
$null = Invoke-Api $net '/v2/live' @{} $cacheLive
Check 'odjezdy hned podruhé z paměti' $script:calls.Count 4
Age $memory ($cacheLive + 1)
$null = Invoke-Api $net '/v2/live' @{} $cacheLive
Check 'odjezdy po pár sekundách znovu na síť' $script:calls.Count 5
$null = Get-Cached $net '/v2/dictionary'
Age $memory 86400
$null = Get-Cached $net '/v2/dictionary'
Check 'číselník se stahuje jednou' $script:calls.Count 6
$null = Test-Token $net
$null = Test-Token $net
Check 'ověření klíče jde na síť pokaždé' $script:calls.Count 8
$bare = @{ Token = 'x'; Demo = $null }
$null = Invoke-Api $bare '/v2/x'
$null = Invoke-Api $bare '/v2/x'
Check 'bez paměti v kontextu se nepamatuje nic' $script:calls.Count 10

# Odmítnutí kvůli limitu (429): po okně limitu druhý pokus, teprve pak chyba. Okno je tu zkrácené, ať test nečeká.
$rateWindow = 0.05
$script:reject = 1
$after = Invoke-Api $net '/v2/busy'
Check 'odmítnuto kvůli limitu: druhý pokus projde' "$($script:calls.Count) $($after.n)" '12 12'
$script:reject = 2
Check 'dvakrát odmítnuto je chyba' (ErrorKind { Invoke-Api $net '/v2/busier' }) 'RateLimited'
Check 'chyba se nepamatuje' "$((Invoke-Api $net '/v2/busier').n) $($script:calls.Count)" '15 15'
$rateWindow = 8.0

# Nepovinné dotazy (kam jede vozidlo) nechávají v okně limitu místo těm, bez kterých karta není.
$limited = @{ Token = 'x'; Demo = $null; Cache = @{}; Limiter = New-Object System.Collections.Queue }
1..12 | ForEach-Object { $limited.Limiter.Enqueue([DateTime]::UtcNow) }
$before = $script:calls.Count
Check 'nepovinný dotaz se při plnějším okně neodešle' "$(ErrorKind { Invoke-Api $limited '/v2/extra' @{} $cacheSlow -Optional }) $($script:calls.Count - $before)" 'Busy 0'
$null = Invoke-Api $limited '/v2/needed'
Check 'povinný dotaz projde' "$($script:calls.Count - $before) $($limited.Limiter.Count)" '1 13'
$moving = Get-Vehicles $limited $lat $lng
Check 'vozidla zatím bez cíle a s příznakem, že něco chybí' "$($moving.Pending) $(@($moving.Items | Where-Object Headsign).Count) $($script:calls.Count - $before)" 'True 0 2'
$limited.Limiter.Clear()
$moving = Get-Vehicles $limited $lat $lng
Check 'cíle se doplní, polohy se znovu nestahují' "$($moving.Pending) $($moving.Items[0].Headsign) $($script:calls.Count - $before)" 'False cíl 991_11452_260202 6'
$null = Get-Vehicles $limited $lat $lng
Check 'potřetí už bez jediného dotazu' ($script:calls.Count - $before) 6
Check 'ukázková data příznak nemají' (Get-Vehicles $demo $lat $lng).Pending $false

# Sada, ke které klíč nesmí: pamatuje se i odmítnutí, jinak by se na ni aplikace ptala při každém obnovení.
$before = $script:calls.Count
Check 'bez přístupu' "$(ErrorKind { Invoke-Api $net '/v2/forbidden' }) $(ErrorKind { Invoke-Api $net '/v2/forbidden' }) $($script:calls.Count - $before)" 'Forbidden Forbidden 1'
Age $memory ($cacheSlow + 1)
Check 'po deseti minutách se zeptá znovu' "$(ErrorKind { Invoke-Api $net '/v2/forbidden' }) $($script:calls.Count - $before)" 'Forbidden 2'
# Zpátky skutečné funkce a hodnoty.
. (Join-Path $root 'Golemio.ps1')

'--- nastavení'
$found = @(Find-Address $demo 'náměstí Míru')
Check 'nalezené adresy' $found.Count 3
Check 'první adresa' "$($found[0].Name.Split(',')[0]) $($found[0].Latitude) $($found[0].Longitude)" 'Náměstí Míru 50.0753 14.4379'
Check 'krátká jména do pole s adresou' (($found | ForEach-Object Label) -join ' | ') 'Náměstí Míru, Vinohrady | náměstí Míru, Zbraslav | náměstí Míru 8/2, Mělník'
Check 'dům: ulice s číslem místo čísla na začátku' (Format-Place @{ display_name = '586/2, Korunní, Vinohrady, Praha'; address = @{ road = 'Korunní'; house_number = '586/2'; suburb = 'Vinohrady' } }) 'Korunní 586/2, Vinohrady'
Check 'ulice bez čísla: začátek celého jména' (Format-Place @{ display_name = 'Korunní, Vinohrady, Praha 2, Česko'; address = @{ road = 'Korunní' } }) 'Korunní, Vinohrady'
Check 'místo se jménem čtvrti se neopakuje' (Format-Place @{ name = 'Vinohrady'; display_name = 'Vinohrady, Praha'; address = @{ suburb = 'Vinohrady'; city = 'Praha' } }) 'Vinohrady, Praha'
Check 'ověření klíče' (Test-Token $demo) $true

'--- místa, kde si specifikace API protiřečí'
$quirks = Join-Path ([IO.Path]::GetTempPath()) "sluzbak-test-$PID"
Copy-Item $demo.Demo $quirks -Recurse
try {
    $alt = @{ Token = ''; Demo = $quirks }
    $utf8 = New-Object Text.UTF8Encoding $false

    # Index ovzduší jako číslo (tak ho uvádí specifikace) se páruje podle id.
    $history = "$quirks\v2-airqualitystations-history.json"
    $text = [IO.File]::ReadAllText($history) -replace '"AQ_hourly_index": "2A"', '"AQ_hourly_index": 3'
    [IO.File]::WriteAllText($history, $text, $utf8)
    Check 'index jako číslo' (Get-Air $alt $lat $lng).Index 'Přijatelná'

    # Neznámý index se ukáže aspoň kódem.
    [IO.File]::WriteAllText($history, ($text -replace '"AQ_hourly_index": 3', '"AQ_hourly_index": "9Z"'), $utf8)
    Check 'neznámý index' (Get-Air $alt $lat $lng).Index 'Index 9Z'

    # Bez historie zbývá stav ze seznamu stanic. Ten je dva měsíce starý (tak to Golemio naživo vracelo)
    # a jako aktuální se ukázat nesmí.
    Remove-Item $history
    Check 'staré měření ovzduší' (Get-Air $alt $lat $lng).Empty 'Golemio má poslední měření ovzduší z 12. 8. v 8:45. Novější teď neposkytuje.'

    # Čerstvý stav v seznamu stanic se bez historie použije.
    $stations = [IO.File]::ReadAllText("$quirks\v2-airqualitystations.json") -replace '2026-08-12T06:45:00\.621Z', '{{now-25}}'
    [IO.File]::WriteAllText("$quirks\v2-airqualitystations.json", $stations, $utf8)
    $listed = Get-Air $alt $lat $lng
    Check 'bez historie: čerstvý stav ze seznamu' "$($listed.Index) $($listed.Components[0].Value)" 'Zhoršená až špatná 77,7 µg/m³'
    [IO.File]::WriteAllText($history, $text, $utf8)

    # Body mikroklimatu jako jeden objekt místo seznamu.
    [IO.File]::WriteAllText("$quirks\v2-microclimate-points.json",
        '{"point_id": 207, "location_id": 200, "point_name": "Jediný bod", "lat": 50.0779, "lng": 14.45, "measures": []}', $utf8)
    $single = Get-Microclimate $alt $lat $lng
    CheckMatch 'jeden bod místo seznamu' $single.Meta '^Jediný bod · \d+ m$'
    Check 'bez číselníku veličin zůstane kód' ($single.Values | Where-Object Name -eq 'uv_index').Value '2'

    # Když za poslední hodiny neměřil žádný senzor (naživo od dubna 2026), karta to řekne rovnou.
    [IO.File]::WriteAllText("$quirks\v2-microclimate-measurements.json", '[]', $utf8)
    Check 'mikroklima bez měření' (Get-Microclimate $alt $lat $lng).Empty 'Golemio teď nemá čerstvá data z žádného senzoru mikroklimatu.'

    # Kam spoj jede, je v samostatném dotazu; když selže, vozidlo se ukáže bez cíle.
    Remove-Item "$quirks\v2-public-gtfs-trips-22_1840_260901.json"
    $noTrip = (Get-Vehicles $alt $lat $lng).Items | Where-Object Route -eq '22'
    Check 'vozidlo bez popisu spoje' "$($noTrip.Headsign)|$($noTrip.State)" '|směr Z'

    # Klíč bez přístupu k velkoobjemovým kontejnerům: část se schová, není to chyba.
    function Invoke-Api($context, [string]$path, $query = @{}, [int]$maxAge) {
        if ($path -eq '/v1/bulky-waste/stations') { throw (ConvertTo-ApiError 403) }
        Read-Demo $context.Demo $path
    }
    $forbidden = Get-Waste $alt $lat $lng
    Check 'velkoobjemové bez přístupu' "$($forbidden.ShowBulky)|$($forbidden.BulkyNote)|$($forbidden.Stations.Count)" 'False||2'
    . (Join-Path $root 'Golemio.ps1')

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
    $bare = Get-Air $alt $lat $lng
    Check 'bez číselníku: hodnota bez jednotky' $bare.Components[0].Value '38,4'

    # S pamětí v kontextu se odpověď deset minut nečte znovu, ani když se mezitím změnila.
    $kept = @{ Token = ''; Demo = $quirks; Cache = @{} }
    $null = Get-Alerts $kept $lat $lng
    [IO.File]::WriteAllText("$quirks\v3-pid-infotexts.json", '[]', $utf8)
    Check 'mimořádnosti do deseti minut z paměti' (Get-Alerts $kept $lat $lng).Meta '3 v celé síti'
    foreach ($key in @($kept.Cache.Keys)) { $kept.Cache[$key].At = $kept.Cache[$key].At.AddSeconds(-($cacheSlow + 1)) }
    Check 'po deseti minutách nová odpověď' (Get-Alerts $kept $lat $lng).Empty 'PID teď žádnou mimořádnost nehlásí.'

    # Nástupiště kolem místa se pamatují: podruhé se seznam zastávek nečte (tady už ani není z čeho).
    $once = @(Find-Stops $kept $lat $lng)
    Remove-Item "$quirks\v2-gtfs-stops.json"
    Check 'zastávky podruhé z paměti' "$($once.Count) $(@(Find-Stops $kept $lat $lng).Count)" '5 5'
    $kept.Options = @{ StopsRange = 300 }
    Check 'jiný okruh se hledá znovu' (ErrorKind { Find-Stops $kept $lat $lng }) 'NotFound'
} finally {
    Remove-Item $quirks -Recurse -Force
}

'--- verze'
$inApp = if ([IO.File]::ReadAllText((Join-Path $root 'Sluzbak.ps1')) -match "\`$version = '([\d.]+)'") { $Matches[1] }
$inLog = if ([IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md')) -match '(?m)^## \[(\d+\.\d+\.\d+)\]') { $Matches[1] }
CheckMatch 'aplikace zná svou verzi' $inApp '^\d+\.\d+\.\d+$'
Check 'verze v aplikaci je nejnovější verze v CHANGELOGu' $inApp $inLog

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
