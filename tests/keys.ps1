# Klávesnice a myš v nastavení: Enter, šipky a kliknutí na nalezenou adresu.
#   powershell -ExecutionPolicy Bypass -File tests/keys.ps1
#
# Aplikace běží přímo v tomhle procesu, s ukázkovými daty a nastavením v dočasné složce. Klávesy dostává
# jako události WPF: skutečné stisky by skončily v okně, které máš zrovna otevřené. Síť test nevolá.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$root = Split-Path $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) "golemwatch-keys-$PID"
$settings = Join-Path $temp 'settings.json'
$script:fail = 0
# Co se vypíše z obsluhy události, se ztratí; řádky se proto sbírají a vypíšou až po zavření okna.
$script:lines = New-Object System.Collections.ArrayList

function Note([string]$line) { $null = $script:lines.Add($line) }
function Check($what, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Note "ok    $what = $actual" }
    else { $script:fail++; Note "FAIL  $what = '$actual' (čekáno '$expected')" }
}

function Press($element, [string]$key) {
    $source = [Windows.PresentationSource]::FromVisual($element)
    foreach ($routed in [Windows.Input.Keyboard]::PreviewKeyDownEvent, [Windows.Input.Keyboard]::KeyDownEvent) {
        $e = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $source, 0, [Windows.Input.Key]$key)
        $e.RoutedEvent = $routed
        $element.RaiseEvent($e)
        # Klávesa zpracovaná cestou dolů už k běžné obsluze nedojde, stejně jako u skutečného stisku.
        if ($e.Handled) { return }
    }
}
function Click($button) { $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
function Release($element) {
    $e = [Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, 'Left')
    $e.RoutedEvent = [Windows.UIElement]::PreviewMouseLeftButtonUpEvent
    $element.RaiseEvent($e)
}
function Searches { @($jobs | Where-Object { $_.Key -eq 'Find' }).Count }
function Place { "$($ui.AddressBox.Text) | $($ui.LatitudeBox.Text) $($ui.LongitudeBox.Text)" }
# Fokus jde ověřit jen v aktivním okně; když zrovna pracuješ jinde, Windows ho oknu testu nedají.
function CheckFocus($what, $element) {
    if ($window.IsActive) { Check $what $element.IsKeyboardFocusWithin $true }
    else { Note "--    ${what}: okno není aktivní, přeskočeno" }
}

# Kroky: počkej na podmínku, pak proveď. Hledání adresy i ověření klíče běží na pozadí, proto to čekání.
$script:steps = New-Object System.Collections.Queue
function Step([string]$name, [scriptblock]$wait, [scriptblock]$do) { $script:steps.Enqueue(@{ Name = $name; Wait = $wait; Do = $do }) }

Step 'ukázkový přehled' { $window -and $window.IsLoaded -and $ui.DashboardView.IsEnabled } {
    $null = $window.Activate()
    Show-Setup
    $ui.AddressBox.Text = 'náměstí Míru'
    Press $ui.AddressBox 'Return'
    Check 'Enter v poli adresy hledá' "$($state.Finding) $($ui.SetupStatus.Text)" 'True Hledám…'
    Check 'tlačítko Najít zůstává zapnuté' $ui.FindButton.IsEnabled $true
    Press $ui.AddressBox 'Return'
    Click $ui.FindButton
    Check 'další Enter ani klik druhé hledání nespustí' (Searches) 1
}
Step 'první hledání' { -not $state.Finding } {
    Check 'nalezené adresy, první vybraná' "$($ui.ResultsList.Items.Count) $($ui.ResultsList.SelectedIndex) $($ui.ResultsList.Visibility)" '3 0 Visible'
    Check 'první adresa se vyplní sama' (Place) 'Náměstí Míru, Vinohrady | 50.0753 14.4379'
    Press $ui.AddressBox 'Down'
    Check 'šipka dolů vybere další adresu a vyplní ji' "$($ui.ResultsList.SelectedIndex) $(Place)" '1 náměstí Míru, Zbraslav | 49.9713 14.3923'
    Press $ui.AddressBox 'Down'
    Press $ui.AddressBox 'Down'
    Check 'šipka dolů končí na poslední' "$($ui.ResultsList.SelectedIndex) $($ui.AddressBox.Text)" '2 náměstí Míru 8/2, Mělník'
    1..3 | ForEach-Object { Press $ui.AddressBox 'Up' }
    Check 'šipka nahoru končí na první' "$($ui.ResultsList.SelectedIndex) $(Place)" '0 Náměstí Míru, Vinohrady | 50.0753 14.4379'

    $ui.ResultsList.SelectedIndex = 1
    Check 'kliknutí na jinou adresu ji vyplní' (Place) 'náměstí Míru, Zbraslav | 49.9713 14.3923'
    $ui.AddressBox.Text = 'přepsáno'
    $ui.LatitudeBox.Text = ''
    Release $ui.ResultsList
    Check 'kliknutí na už vybranou adresu ji vyplní znovu' (Place) 'náměstí Míru, Zbraslav | 49.9713 14.3923'
    $ui.ResultsList.SelectedIndex = 0

    Press $ui.AddressBox 'Return'
    Check 'Enter u nalezené adresy už nehledá, ale ukládá' "$($state.Finding) $($ui.SetupStatus.Text)" 'False Vlož klíč ke Golemio API.'
    CheckFocus 'bez klíče skočí kurzor do pole s klíčem' $ui.TokenBox

    $ui.TokenBox.Password = 'testovaci-klic'
    $ui.AddressBox.Text = 'Korunní 2'
    $null = $ui.FindButton.Focus()
    Click $ui.FindButton
    Check 'přepsaná adresa se hledá znovu' $state.Finding $true
}
Step 'druhé hledání' { -not $state.Finding } {
    # Enter na tlačítku Najít by hledal pořád dokola, proto se po hledání vrací kurzor do pole.
    CheckFocus 'po kliknutí na Najít je kurzor v poli adresy' $ui.AddressBox
    Press $ui.ResultsList 'Return'
    Check 'Enter v seznamu adres ukládá' "$($ui.SetupView.IsEnabled) $($ui.SetupStatus.Text)" 'False Ověřuju klíč…'
}
Step 'uložení ze seznamu' { $ui.DashboardView.IsEnabled -and -not $state.Manual } {
    Check 'přehled s vybranou adresou' $ui.PlaceText.Text 'Náměstí Míru, Vinohrady'
    Check 'nastavení je na disku' (Test-Path $settings) $true
    # Kdy se která odpověď stáhla; po F5 se smí změnit jen to, co už není čerstvé.
    $script:fetched = @{}
    foreach ($key in @($cache.Keys)) { $script:fetched[$key] = $cache[$key].At }
    Press $window 'F5'
    Check 'F5 obnoví přehled' $state.Manual $true
}
Step 'obnovení klávesou F5' { -not $state.Manual } {
    $again = @($script:fetched.Keys | Where-Object { $cache[$_].At -ne $script:fetched[$_] })
    Check 'v paměti jsou odpovědi pro karty na záložce' ($script:fetched.Count -ge 8) $true
    Check 'F5 nestahuje znovu, co je čerstvé' "$($again.Count)" '0'
    Check 'karty mají data dál' "$($ui.TransitBody.Visibility) $($ui.AlertsBody.Visibility)" 'Visible Visible'

    Show-Setup
    Check 'uložená adresa je v poli' $ui.AddressBox.Text 'Náměstí Míru, Vinohrady'
    $ui.AddressBox.Text = 'Korunní'
    Press $ui.AddressBox 'Return'
    Check 'přepsaná uložená adresa se Enterem nejdřív hledá' $state.Finding $true
}
Step 'třetí hledání' { -not $state.Finding } {
    Press $ui.AddressBox 'Return'
    Check 'druhý Enter v poli adresy ukládá' "$($ui.SetupView.IsEnabled) $($ui.SetupStatus.Text)" 'False Ověřuju klíč…'
}
Step 'uložení z pole adresy' { $ui.DashboardView.IsEnabled } {
    Check 'zpět v přehledu' $ui.PlaceText.Text 'Náměstí Míru, Vinohrady'
    Show-Setup
    Press $ui.AddressBox 'Return'
    Check 'Enter u uložené adresy beze změny rovnou ukládá' "$($state.Finding) $($ui.SetupView.IsEnabled) $($ui.SetupStatus.Text)" 'False False Ověřuju klíč…'
}
Step 'uložení beze změny' { $ui.DashboardView.IsEnabled } {
    Check 'a zase přehled' $ui.PlaceText.Text 'Náměstí Míru, Vinohrady'
}

$script:deadline = [DateTime]::UtcNow.AddSeconds(15)
$script:giveUp = [DateTime]::UtcNow.AddSeconds(90)
$driver = [Windows.Threading.DispatcherTimer]::new()
$driver.Interval = [TimeSpan]::FromMilliseconds(100)
$driver.Add_Tick({
    try {
        if ([DateTime]::UtcNow -gt $script:giveUp) {
            # Okno se neotevřelo nebo visí na hlášce o chybě; bez tohohle by test nikdy neskončil.
            [Console]::WriteLine('FAIL  test nedoběhl do 90 sekund')
            [Environment]::Exit(99)
        }
        if (-not $script:steps.Count) { $driver.Stop(); $window.Close(); return }
        $step = $script:steps.Peek()
        if (-not (& $step.Wait)) {
            if ([DateTime]::UtcNow -lt $script:deadline) { return }
            throw "krok '$($step.Name)' se nedočkal své podmínky"
        }
        $null = $script:steps.Dequeue()
        Note "--- $($step.Name)"
        & $step.Do
        $script:deadline = [DateTime]::UtcNow.AddSeconds(15)
    } catch {
        $script:fail++
        Note "FAIL  $_"
        $script:steps.Clear()
    }
})

$null = New-Item -ItemType Directory -Force $temp
try {
    $driver.Start()
    . (Join-Path $root 'GolemWatch.ps1') -Demo -SettingsPath $settings
} finally {
    $driver.Stop()
    Remove-Item $temp -Recurse -Force
}
if ($script:steps.Count) { $script:fail++; Note "FAIL  nedošlo na kroky: $(@($script:steps | ForEach-Object { $_.Name }) -join ', ')" }
$script:lines
"---"; "chyb: $script:fail"
exit $script:fail
