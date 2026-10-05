# End-to-end test GolemWatch přes UI Automation:
#   powershell -ExecutionPolicy Bypass -File tests/e2e.ps1
#
# Aplikace běží s ukázkovými daty a s nastavením v dočasné složce: test nevolá síť a na tvoje
# nastavení v %APPDATA% nesáhne. Během testu se na obrazovce několikrát otevře a zavře okno aplikace.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [Windows.Automation.AutomationElement]
$root = Split-Path $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) "golemwatch-e2e-$PID"
$settings = Join-Path $temp 'settings.json'
$script:fail = 0

function Launch([string]$app = (Join-Path $root 'GolemWatch.ps1'), [switch]$Demo) {
    $arguments = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$app`"", '-SettingsPath', "`"$settings`""
    if ($Demo) { $arguments += '-Demo' }
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $arguments
    $ofProcess = New-Object Windows.Automation.PropertyCondition ($AE::ProcessIdProperty, $p.Id)
    $script:window = $null
    for ($i = 0; $i -lt 200 -and -not $script:window; $i++) {
        Start-Sleep -Milliseconds 50
        $script:window = $AE::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $ofProcess)
    }
    if (-not $script:window) { Stop-Process -Id $p.Id -ErrorAction SilentlyContinue; throw 'Okno GolemWatch se neobjevilo.' }
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
function Pick($name) { (FindNamed $name).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 250 }
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
    Check 'ukázka: štítek' (Named 'ukázková data') $true
    Check 'ukázka nic neukládá' (Test-Path $settings) $false
    Invoke SettingsButton
    Check 'z ukázky se dá vrátit' (Shown BackButton) $true
    Check 'ukázka se podruhé nenabízí' (Shown DemoButton) $false
    Check 'zavření okna ukončí proces' (Close $p) $true

    '--- nastavení od začátku do konce (s -Demo odpovídají ukázkové soubory i hledání adresy a ověření klíče)'
    $p = Launch -Demo
    Check 's -Demo a bez nastavení rovnou přehled' (WaitFor { Named 'Depo Hostivař' }) $true
    Invoke SettingsButton
    SetValue TokenBox 'testovaci-klic'
    SetValue AddressBox 'náměstí Míru'
    Invoke FindButton
    Check 'první adresa vyplní šířku' (WaitFor { (Value LatitudeBox) -eq '50.0753' }) $true
    Check 'první adresa vyplní délku' (Value LongitudeBox) '14.4379'
    Check 'hláška po hledání' (Text SetupStatus) 'Vybral jsem první výsledek. Jestli nesedí, klikni na jiný.'
    Pick 'náměstí Míru, Zbraslav, Praha 16, Hlavní město Praha, 156 00, Česko'
    Check 'jiná adresa přepíše souřadnice' "$(Value LatitudeBox) $(Value LongitudeBox)" '49.9713 14.3923'
    Pick 'Náměstí Míru, Vinohrady, Praha 2, Hlavní město Praha, 120 00, Česko'
    SetValue LatitudeBox ' 50,0753° '
    Invoke SaveButton
    Check 'po uložení přehled s novým místem' (WaitFor { (Text PlaceText) -eq 'náměstí Míru' }) $true
    Check 'desetinná čárka a stupně v souřadnici' (Text CoordinatesText) '50.0753, 14.4379'

    Check 'odjezdy' (WaitFor { Named 'Depo Hostivař' }) $true
    Check 'odjezdy: zastávky' (Text TransitMeta) 'Náměstí Míru, Šumavská'
    Check 'odjezdy: zpoždění' (NamedLike '^\d{1,2}:\d\d \+2 min$') $true
    Check 'odjezdy: zrušený spoj' (Named 'zrušeno') $true
    Check 'odjezdy: mimořádnost' (Named 'Výluka Korunní: linka 10 jede odklonem přes Flora a zastávku Šumavská neobsluhuje.') $true
    Check 'odpad: stanoviště' (WaitFor { Named 'Náměstí Míru 820/9' }) $true
    Check 'odpad: počet' (Text WasteMeta) '2 nejbližší'
    Check 'odpad: velkoobjemový kontejner' (Named 'Budečská × Francouzská') $true
    Check 'ovzduší: index' (WaitFor { Named 'Přijatelná' }) $true
    Check 'ovzduší: stanice' (Text AirMeta) 'Praha 2-Legerova · 620 m'
    Check 'mikroklima: hodnota' (WaitFor { Named '14,2 °C' }) $true
    Check 'parkování: volná místa' (WaitFor { Named 'volných z 180' }) $true
    Check 'parkování: režim a vzdálenost' (Named 'Placené · 520 m') $true
    Check 'v okolí: nejbližší lékárna' (WaitFor { Named 'Lékárna U Ludmily' }) $true
    Check 'v okolí: otevírací doba' (Named 'otevřeno nonstop') $true
    Check 'v okolí: sběrný dvůr' (Named 'Sběrný dvůr Perucká') $true
    Check 'stavové texty jsou schované' "$(Shown TransitState)$(Shown NearbyState)$(Shown WasteState)$(Shown AirState)$(Shown MicroclimateState)$(Shown ParkingState)" 'FalseFalseFalseFalseFalseFalse'
    Check 'čas aktualizace' ((Text UpdatedText) -match '^aktualizováno \d{1,2}:\d\d$') $true

    Check 'nastavení je na disku' (Test-Path $settings) $true
    $saved = [IO.File]::ReadAllText($settings, [Text.Encoding]::UTF8)
    Check 'klíč v něm není čitelný' ($saved -notmatch 'testovaci-klic') $true
    Check 'místo je uložené' (($saved | ConvertFrom-Json).place) 'náměstí Míru'

    Invoke RefreshButton
    Check 'obnovení doběhne' (WaitFor { (Find RefreshButton).Current.IsEnabled }) $true
    Check 'po obnovení data zůstanou' (Named 'Depo Hostivař') $true
    Check 'zavření okna ukončí proces' (Close $p) $true

    '--- druhé spuštění: nastavení se načte z disku'
    $p = Launch -Demo
    Check 'rovnou přehled s uloženým místem' (WaitFor { (Text PlaceText) -eq 'náměstí Míru' }) $true
    Check 'data se načtou' (WaitFor { Named 'Depo Hostivař' }) $true
    Invoke SettingsButton
    Check 'formulář je předvyplněný' "$(Value AddressBox)|$(Value LatitudeBox)|$(Value LongitudeBox)" 'náměstí Míru|50.0753|14.4379'
    Invoke BackButton
    Check 'zpět na přehled' (Text PlaceText) 'náměstí Míru'
    Check 'po návratu data nezmizela' (Named 'Depo Hostivař') $true
    $null = Close $p

    '--- chyba v jedné sekci nezboří ostatní'
    $copy = Join-Path $temp 'app'
    $null = New-Item -ItemType Directory -Force $copy
    Copy-Item (Join-Path $root 'GolemWatch.ps1'), (Join-Path $root 'GolemWatch.xaml'), (Join-Path $root 'Golemio.ps1') $copy
    Copy-Item (Join-Path $root 'demo') $copy -Recurse
    Remove-Item (Join-Path $copy 'demo\v3-parking.json')
    $p = Launch (Join-Path $copy 'GolemWatch.ps1') -Demo
    Check 'ostatní sekce jedou' (WaitFor { Named 'Depo Hostivař' }) $true
    Check 'chyba je vidět v kartě' (WaitFor { (Text ParkingState) -eq 'Ukázková data pro /v3/parking chybí.' }) $true
    Check 'ovzduší jede dál' (Named 'Přijatelná') $true
    $null = Close $p
}
finally {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id }
    Remove-Item $temp -Recurse -Force
}
"---"; "chyb: $script:fail"
exit $script:fail
