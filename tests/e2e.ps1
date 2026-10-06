# End-to-end test aplikace přes UI Automation:
#   powershell -ExecutionPolicy Bypass -File tests/e2e.ps1
#
# Aplikace běží s ukázkovými daty a s nastavením v dočasné složce: test nevolá síť a na tvoje
# nastavení v %APPDATA% nesáhne. Během testu se na obrazovce několikrát otevře a zavře okno aplikace.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [Windows.Automation.AutomationElement]
$root = Split-Path $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) "sluzbak-e2e-$PID"
$settings = Join-Path $temp 'settings.json'
$script:fail = 0

function Launch([string]$app = (Join-Path $root 'Sluzbak.ps1'), [switch]$Demo) {
    $arguments = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$app`"", '-SettingsPath', "`"$settings`""
    if ($Demo) { $arguments += '-Demo' }
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $arguments
    $ofProcess = New-Object Windows.Automation.PropertyCondition ($AE::ProcessIdProperty, $p.Id)
    $script:window = $null
    for ($i = 0; $i -lt 200 -and -not $script:window; $i++) {
        Start-Sleep -Milliseconds 50
        $script:window = $AE::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $ofProcess)
    }
    if (-not $script:window) { Stop-Process -Id $p.Id -ErrorAction SilentlyContinue; throw 'Okno aplikace se neobjevilo.' }
    Start-Sleep -Milliseconds 500
    $p
}
# Zavře okno tak, jak to dělá uživatel, a počká, že skončí i proces (rozdělané úlohy na pozadí ho nesmí držet).
function Close($p) {
    $script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
    $exited = $p.WaitForExit(5000)
    if (-not $exited) { Stop-Process -Id $p.Id }
    $exited
}
function Find($id) {
    $byId = New-Object Windows.Automation.PropertyCondition ($AE::AutomationIdProperty, $id)
    $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants, $byId)
}
function FindNamed($name) {
    $byName = New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, $name)
    $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants, $byName)
}
# Schované prvky v automatizačním stromu zůstávají, jen jsou označené jako mimo obrazovku.
function Visible($e) { $null -ne $e -and -not $e.Current.IsOffscreen }
function Shown($id) { Visible (Find $id) }
function Named($name) { Visible (FindNamed $name) }
# Text složený z více částí (čas a zpoždění) má jméno dohromady, proto hledání podle vzoru.
function NamedLike($pattern) {
    $all = $script:window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    @($all | Where-Object { $_.Current.Name -match $pattern -and -not $_.Current.IsOffscreen }).Count -gt 0
}
function Text($id) { $e = Find $id; if ($e) { $e.Current.Name } else { '<nenalezeno>' } }
function Value($id) { (Find $id).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value }
function SetValue($id, $v) { (Find $id).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($v); Start-Sleep -Milliseconds 250 }
function Invoke($id) { (Find $id).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep -Milliseconds 400 }
function Toggle($id) { (Find $id).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle(); Start-Sleep -Milliseconds 250 }
function Toggled($id) { (Find $id).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState }
function Pick($name) { (FindNamed $name).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 250 }
function States($names) { ($names | ForEach-Object { Shown "${_}State" }) -join ' ' }
# Kolik bodů od levého okraje okna prvek začíná.
function Left($id) { [int]((Find $id).Current.BoundingRectangle.Left - $script:window.Current.BoundingRectangle.Left) }
function Collapsed { @(([IO.File]::ReadAllText($settings, [Text.Encoding]::UTF8) | ConvertFrom-Json).options.collapsed) -join ',' }
function WaitFor([scriptblock]$condition, [int]$seconds = 15) {
    $until = [DateTime]::UtcNow.AddSeconds($seconds)
    while ([DateTime]::UtcNow -lt $until) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 200
    }
    $false
}
function Check($what, $actual, $expected) {
    if ("$actual" -ceq "$expected") { "ok    $what = $actual" }
    else { $script:fail++; "FAIL  $what = '$actual' (čekáno '$expected')" }
}

# Sekce přehledu ve stejném pořadí jako ve Sluzbak.ps1.
$sections = 'Transit', 'Vehicles', 'Waste', 'Alerts', 'Cars', 'Cycling', 'Air', 'Microclimate', 'Parking', 'Nearby'
$needPlace = 'Najdi adresu, nebo vyplň souřadnice (třeba 50,0753 a 14,4379).'
$null = New-Item -ItemType Directory -Force $temp
$p = $null
try {
    '--- první spuštění: nastavení (bez -Demo, ale nic z toho se sítě nedotkne)'
    $p = Launch
    Check 'ukáže se nastavení' (Shown SaveButton) $true
    Check 'přehled je schovaný' (Shown RefreshButton) $false
    Check 'nabízí ukázková data' (Shown DemoButton) $true
    Check 'není se kam vracet' (Shown BackButton) $false
    Check 'je vidět číslo verze' ((Text VersionText) -match '^Službák \d+\.\d+\.\d+$') $true
    Check 'volby jsou předvyplněné' "$(Value StopsRangeBox)|$(Value WasteRangeBox)|$(Value ParkingRangeBox)|$(Value DeparturesBox)|$(Value RefreshBox)" '600|400|1500|12|30'
    Check 'všechny karty jsou zapnuté' (($sections | ForEach-Object { Toggled "${_}Chip" }) -join ' ') 'On On On On On On On On On On'
    SetValue StopsRangeBox '4x5 0m'
    Check 'do pole s číslem jdou jen číslice' (Value StopsRangeBox) '450'
    Invoke SaveButton
    Check 'bez klíče to nejde' (Text SetupStatus) 'Vlož klíč ke Golemio API.'
    SetValue TokenBox 'testovaci-klic'
    Invoke SaveButton
    Check 'bez místa to nejde' (Text SetupStatus) $needPlace
    SetValue LatitudeBox '95'
    SetValue LongitudeBox '14.4379'
    Invoke SaveButton
    Check 'šířka mimo rozsah' (Text SetupStatus) $needPlace
    SetValue LatitudeBox 'abc'
    Invoke SaveButton
    Check 'šířka, která není číslo' (Text SetupStatus) $needPlace
    Invoke FindButton
    Check 'hledání bez adresy' (Text SetupStatus) 'Napiš adresu, třeba „Korunní 2, Praha“.'

    Invoke DemoButton
    Check 'ukázka: odjezdy' (WaitFor { Named 'Depo Hostivař' }) $true
    Check 'ukázka: místo' (Text PlaceText) 'Náměstí Míru, Praha 2'
    Check 'ukázka: městská část za souřadnicemi' (WaitFor { (Text CoordinatesText) -eq '50.0753, 14.4379 · Praha 2' }) $true
    Check 'ukázka: štítek' (Named 'ukázková data') $true
    Check 'ukázka: všechny karty jsou rozbalené' (($sections | ForEach-Object { Toggled "${_}Toggle" }) -join ' ') 'On On On On On On On On On On'
    Toggle WasteToggle
    Check 'ukázka: karta jde sbalit' "$(Shown WasteToggle) $(Shown WasteMeta) $(Named 'Náměstí Míru 820/9')" 'True False False'
    Check 'ukázka nic neukládá' (Test-Path $settings) $false
    Invoke SettingsButton
    Check 'z ukázky se dá vrátit' (Shown BackButton) $true
    Check 'ukázka se podruhé nenabízí' (Shown DemoButton) $false
    Check 'zavření okna ukončí proces' (Close $p) $true

    '--- nastavení od začátku do konce (s -Demo odpovídají ukázkové soubory i hledání adresy a ověření klíče)'
    $p = Launch -Demo
    Check 's -Demo a bez nastavení rovnou přehled' (WaitFor { Named 'Depo Hostivař' }) $true
    Toggle WasteToggle
    Invoke SettingsButton
    SetValue TokenBox 'testovaci-klic'
    SetValue AddressBox 'náměstí Míru'
    Invoke FindButton
    Check 'první adresa vyplní šířku' (WaitFor { (Value LatitudeBox) -eq '50.0753' }) $true
    Check 'první adresa vyplní délku' (Value LongitudeBox) '14.4379'
    Check 'hláška po hledání' (Text SetupStatus) 'Vybral jsem první výsledek. Jestli nesedí, klikni na jiný.'
    Check 'první adresa se propíše do pole' (Value AddressBox) 'Náměstí Míru, Vinohrady'
    Pick 'náměstí Míru, Zbraslav, Praha 16, Hlavní město Praha, 156 00, Česko'
    Check 'vybraná adresa přepíše pole i souřadnice' "$(Value AddressBox) | $(Value LatitudeBox) $(Value LongitudeBox)" 'náměstí Míru, Zbraslav | 49.9713 14.3923'
    Pick 'Náměstí Míru, Vinohrady, Praha 2, Hlavní město Praha, 120 00, Česko'
    Check 'a zase zpátky' "$(Value AddressBox) | $(Value LatitudeBox) $(Value LongitudeBox)" 'Náměstí Míru, Vinohrady | 50.0753 14.4379'
    SetValue LatitudeBox ' 50,0753° '
    Invoke SaveButton
    Check 'po uložení přehled s novým místem' (WaitFor { (Text PlaceText) -eq 'Náměstí Míru, Vinohrady' }) $true
    Check 'desetinná čárka a stupně v souřadnici' (WaitFor { (Text CoordinatesText) -eq '50.0753, 14.4379 · Praha 2' }) $true

    Check 'odjezdy' (WaitFor { Named 'Depo Hostivař' }) $true
    Check 'odjezdy: zastávky' (Text TransitMeta) 'Náměstí Míru, Šumavská'
    Check 'odjezdy: zpoždění' (NamedLike '^\d{1,2}:\d\d \+2 min$') $true
    Check 'odjezdy: zrušený spoj' (Named 'zrušeno') $true
    Check 'odjezdy: mimořádnost' (Named 'Výluka Korunní: linka 10 jede odklonem přes Flora a zastávku Šumavská neobsluhuje.') $true
    Check 'jede kolem: počet' (WaitFor { (Text VehiclesMeta) -eq '4 do 1 km' }) $true
    Check 'jede kolem: cíl a směr' (NamedLike '^Bílá Hora\s+směr Z$') $true
    Check 'výluky: počet' (WaitFor { (Text AlertsMeta) -eq '3 v celé síti' }) $true
    Check 'výluky: text' (Named 'Metro C mezi stanicemi Pražského povstání a Kačerov nejede. Využijte náhradní autobusy XC.') $true
    Check 'výluky: zastávky a konec' (NamedLike '^Pražského povstání, Pankrác, Budějovická a další\s+do zítra$') $true
    Check 'parkování: volná místa' (WaitFor { NamedLike '^47\s+volných z 180$' }) $true
    Check 'parkování: vzdálenost a režim' (NamedLike '^Garáže Vinohradská tržnice\s+520 m · Placené$') $true
    Check 'parkování: automat' (Named 'Nejbližší parkovací automat 190 m') $true
    Check 'sdílená auta' (WaitFor { NamedLike '^Škoda Fabia\s+CAR4WAY · benzín · ihned$' }) $true
    Check 'cyklosčítač: sčítač, který něco napočítal' (WaitFor { (Text CyclingMeta) -eq 'Podolské nábřeží · 2,5 km' }) $true
    Check 'cyklosčítač: součet' (NamedLike '^2\s801\s+kol od půlnoci · trasa A 2$') $true
    Check 'sbalení z ukázky se uložilo s nastavením' (Collapsed) 'Waste'
    Check 'sbalená karta se nenačítá' "$(Shown WasteToggle) $(Shown WasteMeta) $(Text WasteMeta)|" 'True False |'
    Toggle WasteToggle
    Check 'rozbalená karta se načte' (WaitFor { Named 'Náměstí Míru 820/9' }) $true
    Check 'odpad: počet' (Text WasteMeta) '2 nejbližší'
    Check 'odpad: žlutý kontejner má srozumitelné jméno' (NamedLike '^Plasty a nápojové kartony\s+Út, Čt, So$') $true
    Check 'odpad: velkoobjemový kontejner' (NamedLike 'Budečská × Francouzská$') $true
    Check 'rozbalení se uložilo' (Collapsed) ''
    Check 'ovzduší: index' (WaitFor { Named 'Přijatelná' }) $true
    Check 'ovzduší: stanice' (Text AirMeta) 'Praha 2-Legerova · 620 m'
    Check 'mikroklima: hodnota' (WaitFor { Named '14,2 °C' }) $true
    Check 'mikroklima: senzor, který měří' ((Text MicroclimateMeta) -match '^Náměstí Jiřího z Poděbrad · ') $true
    Check 'v okolí: nejbližší lékárna' (WaitFor { Named 'Lékárna U Ludmily' }) $true
    Check 'v okolí: otevírací doba' (Named 'otevřeno nonstop') $true
    Check 'v okolí: sběrný dvůr' (Named 'Sběrný dvůr Perucká') $true
    Check 'v okolí: nemocnice a hřiště' "$(Named 'Všeobecná fakultní nemocnice v Praze') $(Named 'Riegrovy sady - Na Smetance')" 'True True'
    Check 'stavové texty jsou schované' (States $sections) 'False False False False False False False False False False'
    Check 'čas aktualizace' ((Text UpdatedText) -match '^aktualizováno \d{1,2}:\d\d$') $true

    Toggle AirToggle
    Check 'sbalená karta: zbylo jen záhlaví' "$(Shown AirToggle) $(Shown AirMeta) $(Named 'Přijatelná')" 'True False False'
    Check 'sousední karta zůstala' (Named '14,2 °C') $true
    Check 'sbalení je na disku' (Collapsed) 'Air'
    Toggle AirToggle
    Check 'čerstvá data jsou po rozbalení hned zpátky' "$(Named 'Přijatelná') $(Text AirMeta)" 'True Praha 2-Legerova · 620 m'
    Toggle AirToggle
    Toggle NearbyToggle

    Check 'nastavení je na disku' (Test-Path $settings) $true
    $saved = [IO.File]::ReadAllText($settings, [Text.Encoding]::UTF8)
    Check 'klíč v něm není čitelný' ($saved -notmatch 'testovaci-klic') $true
    Check 'místo je uložené' (($saved | ConvertFrom-Json).place) 'Náměstí Míru, Vinohrady'

    Invoke RefreshButton
    Check 'obnovení doběhne' (WaitFor { (Find RefreshButton).Current.IsEnabled }) $true
    Check 'po obnovení data zůstanou' (Named 'Depo Hostivař') $true
    $options = ([IO.File]::ReadAllText($settings, [Text.Encoding]::UTF8) | ConvertFrom-Json).options
    Check 'výchozí volby na disku' "$($options.stopsRange)|$($options.wasteRange)|$($options.parkingRange)|$($options.departures)|$($options.refresh)|$(@($options.hidden).Count)" '600|400|1500|12|30|0'

    '--- změna voleb: vypnuté karty, užší okruh, méně odjezdů, čísla mimo meze'
    Invoke SettingsButton
    Toggle WasteChip
    Toggle ParkingChip
    SetValue StopsRangeBox '300'
    SetValue DeparturesBox '4'
    SetValue ParkingRangeBox '99999'
    SetValue RefreshBox '1'
    Invoke SaveButton
    Check 'užší okruh: jen bližší zastávky' (WaitFor { (Text TransitMeta) -eq 'Náměstí Míru' }) $true
    Check 'čtyři odjezdy: čtvrtý je vidět' (WaitFor { Named 'Chodov' }) $true
    Check 'čtyři odjezdy: pátý už ne' (Named 'Sídliště Řepy') $false
    Check 'vypnuté karty zmizely, ostatní zůstaly' "$(Shown ParkingToggle) $(Shown WasteToggle) $(Shown CarsMeta) $(Shown VehiclesMeta) $(Shown MicroclimateMeta)" 'False False True True True'
    Check 'ostatní karty se načtou' (WaitFor { Named '14,2 °C' }) $true
    Check 'sbalené karty zůstaly sbalené i po uložení' "$(Toggled AirToggle) $(Toggled NearbyToggle) $(Shown AirMeta) $(Named 'Lékárna U Ludmily')" 'Off Off False False'
    $options = ([IO.File]::ReadAllText($settings, [Text.Encoding]::UTF8) | ConvertFrom-Json).options
    Check 'volby na disku, čísla srovnaná do mezí' "$($options.stopsRange)|$($options.wasteRange)|$($options.parkingRange)|$($options.departures)|$($options.refresh)|$($options.hidden -join ',')|$($options.collapsed -join ',')" '300|400|5000|4|15|Waste,Parking|Air,Nearby'
    Check 'zavření okna ukončí proces' (Close $p) $true

    '--- druhé spuštění: nastavení se načte z disku'
    $p = Launch -Demo
    Check 'rovnou přehled s uloženým místem' (WaitFor { (Text PlaceText) -eq 'Náměstí Míru, Vinohrady' }) $true
    Check 'data se načtou' (WaitFor { Named 'Depo Hostivař' }) $true
    Check 'všechno je na jedné stránce' (WaitFor { (Named '14,2 °C') -and (NamedLike '^Škoda Fabia\s+CAR4WAY') }) $true
    Check 'vypnutá karta zůstala vypnutá' "$(Shown ParkingToggle) $(Shown CarsMeta)" 'False True'
    Check 'sbalené karty zůstaly sbalené a nenačetly se' "$(Toggled AirToggle) $(Toggled NearbyToggle) $(Toggled TransitToggle)|$(Text AirMeta)|$(Text NearbyMeta)|" 'Off Off On|||'
    Toggle AirToggle
    Check 'po rozbalení se karta načte' (WaitFor { (Named 'Přijatelná') -and (Text AirMeta) -eq 'Praha 2-Legerova · 620 m' }) $true
    Check 'užší okruh platí dál' (Text TransitMeta) 'Náměstí Míru'
    Invoke SettingsButton
    Check 'formulář je předvyplněný' "$(Value AddressBox)|$(Value LatitudeBox)|$(Value LongitudeBox)" 'Náměstí Míru, Vinohrady|50.0753|14.4379'
    Check 'volby jsou předvyplněné' "$(Value StopsRangeBox)|$(Value ParkingRangeBox)|$(Value DeparturesBox)|$(Value RefreshBox)|$(Toggled WasteChip)|$(Toggled ParkingChip)|$(Toggled AirChip)" '300|5000|4|15|Off|Off|On'
    $on = @($sections | Where-Object { $_ -notin 'Waste', 'Parking' })
    $on | ForEach-Object { Toggle "${_}Chip" }
    Invoke SaveButton
    Check 'aspoň jedna karta musí zůstat' (Text SetupStatus) 'Nech zapnutou aspoň jednu kartu.'
    Invoke BackButton
    Check 'zpět na přehled' (Text PlaceText) 'Náměstí Míru, Vinohrady'
    Check 'po návratu data nezmizela' (Named 'Depo Hostivař') $true

    '--- sloupec, ve kterém nezbyla žádná karta, se zavře'
    $before = Left AlertsToggle
    Invoke SettingsButton
    'Transit', 'Vehicles' | ForEach-Object { Toggle "${_}Chip" }
    Invoke SaveButton
    Check 'zbylé karty jedou dál' (WaitFor { Named '14,2 °C' }) $true
    Check 'karty prvního sloupce zmizely' "$(Shown TransitToggle) $(Shown VehiclesToggle) $(Shown AlertsToggle)" 'False False True'
    Check 'druhý sloupec se posunul na kraj' "$($before -gt 300) $((Left AlertsToggle) -lt 150)" 'True True'
    $null = Close $p

    '--- nastavení ze starší verze (bez voleb) se načte s výchozími hodnotami'
    $token = ConvertTo-SecureString 'testovaci-klic' -AsPlainText -Force | ConvertFrom-SecureString
    $old = [ordered]@{ token = $token; place = 'Staré nastavení'; latitude = 50.0753; longitude = 14.4379 } | ConvertTo-Json
    [IO.File]::WriteAllText($settings, $old, (New-Object Text.UTF8Encoding $false))
    $p = Launch -Demo
    Check 'starý soubor se načte' (WaitFor { (Text PlaceText) -eq 'Staré nastavení' }) $true
    Check 'všechny karty jsou vidět' (WaitFor { NamedLike '^47\s+volných z 180$' }) $true
    Check 'výchozí okruh zastávek' (Text TransitMeta) 'Náměstí Míru, Šumavská'
    Invoke SettingsButton
    Check 'výchozí volby ve formuláři' "$(Value StopsRangeBox)|$(Value DeparturesBox)|$(Value RefreshBox)|$(Toggled ParkingChip)" '600|12|30|On'
    Invoke BackButton
    Check 'všechny karty jsou rozbalené' (($sections | ForEach-Object { Toggled "${_}Toggle" }) -join ' ') 'On On On On On On On On On On'
    $null = Close $p

    '--- chyba v jedné sekci nezboří ostatní'
    $copy = Join-Path $temp 'app'
    $null = New-Item -ItemType Directory -Force $copy
    Copy-Item (Join-Path $root 'Sluzbak.ps1'), (Join-Path $root 'Sluzbak.xaml'), (Join-Path $root 'Golemio.ps1') $copy
    Copy-Item (Join-Path $root 'demo') $copy -Recurse
    Remove-Item (Join-Path $copy 'demo\v3-parking.json')
    $p = Launch (Join-Path $copy 'Sluzbak.ps1') -Demo
    Check 'ostatní sekce jedou' (WaitFor { Named 'Depo Hostivař' }) $true
    Check 'chyba je vidět v kartě' (WaitFor { (Text ParkingState) -eq 'Ukázková data pro /v3/parking chybí.' }) $true
    Check 'sousední karta jede dál' (WaitFor { NamedLike '^Škoda Fabia\s+CAR4WAY' }) $true
    $null = Close $p
}
finally {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id }
    Remove-Item $temp -Recurse -Force
}
"---"; "chyb: $script:fail"
exit $script:fail
