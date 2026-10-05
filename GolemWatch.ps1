# GolemWatch: přehled pražských dat z Golemio API kolem jednoho místa.
# Okno je popsané v GolemWatch.xaml, data čte Golemio.ps1 na pozadí.
#   GolemWatch.ps1                         spustí aplikaci
#   GolemWatch.ps1 -Install                vytvoří zástupce s ikonou v nabídce Start, na ploše a ve složce s aplikací
#   GolemWatch.ps1 -Demo                   místo sítě čte ukázková data ze složky demo (bez klíče i bez internetu)
#   GolemWatch.ps1 -SettingsPath <soubor>  nastavení jinde než v %APPDATA% (pro testy)
#   GolemWatch.ps1 -Screenshot <png>       po načtení uloží obrázek okna a skončí (obrázky do README)
#   GolemWatch.ps1 -Page <Traffic|Around>  záložka, kterou okno otevře (hodí se k -Screenshot)
param([switch]$Install, [switch]$Demo, [string]$SettingsPath, [string]$Screenshot, [string]$Page)

$ErrorActionPreference = 'Stop'
# Číslo vydání. Musí sedět s nejnovější verzí v CHANGELOG.md (hlídá tests/unit.ps1), bere si ho tools/make-release.ps1.
$version = '0.1.0'
$icon = Join-Path $PSScriptRoot 'assets\golemwatch.ico'
$library = Join-Path $PSScriptRoot 'Golemio.ps1'
$demoDirectory = Join-Path $PSScriptRoot 'demo'

if ($Install) {
    # Soubory rozbalené ze ZIPu staženého prohlížečem nesou značku "z internetu" a Windows se u nich
    # může ptát nebo je odmítnout. Po instalaci už značku nemají. (Kde to nejde, zůstane vše při starém.)
    Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    $shell = New-Object -ComObject WScript.Shell
    # Nabídka Start, plocha a složka s aplikací (ať je i tam na co kliknout).
    foreach ($directory in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('DesktopDirectory'), $PSScriptRoot) {
        $path = Join-Path $directory 'GolemWatch.lnk'
        $link = $shell.CreateShortcut($path)
        # conhost --headless spustí PowerShell bez okna konzole.
        $link.TargetPath = "$env:SystemRoot\System32\conhost.exe"
        $link.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $link.WorkingDirectory = $PSScriptRoot
        $link.IconLocation = $icon
        # WScript.Shell ukládá texty v kódové stránce systému, proto je popisek bez háčků a čárek.
        $link.Description = 'Praha kolem tebe: odpad, ovzdusi, parkovani a MHD'
        $link.Save()
        if ($shell.CreateShortcut($path).Arguments -ne $link.Arguments) {
            Remove-Item $path
            throw "Cesta $PSScriptRoot obsahuje znaky, které zástupce neunese. Přesuň složku jinam a zkus to znovu."
        }
    }
    'Hotovo. Zástupce GolemWatch je v nabídce Start, na ploše a v téhle složce.'
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. $library

# Volání Windows API pro tmavý titulek. Když se Add-Type nepovede (třeba kvůli zásadám počítače),
# aplikace běží dál, jen má titulek světlý.
$native = $null
try {
    $native = Add-Type -Namespace GolemWatch -Name Native -PassThru -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
'@
} catch { }

# Cesty z parametrů mohou být relativní k aktuální složce PowerShellu; .NET by je bral od složky procesu.
function Resolve-Target([string]$path) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path) }
$SettingsPath = if ($SettingsPath) { Resolve-Target $SettingsPath } else { Join-Path $env:APPDATA 'GolemWatch\settings.json' }
if ($Screenshot) { $Screenshot = Resolve-Target $Screenshot }

# Ukázkové místo: k náměstí Míru patří soubory ve složce demo.
$demoPlace = @{ Name = 'Náměstí Míru, Praha 2'; Latitude = 50.0753; Longitude = 14.4379 }
$unnamed = 'Vlastní místo'

# Přehled má záložky a na každé několik sekcí (karet). Ke každé sekci patří funkce Get-<sekce> v Golemio.ps1,
# v přehledu prvky <sekce>Card, <sekce>Meta, <sekce>State a <sekce>Body a v nastavení štítek <sekce>Chip.
# Záložka má v okně tlačítko <záložka>Tab a mřížku <záložka>Page se sloupci <záložka>Column1 až 3.
$pages = [ordered]@{
    Traffic = 'Transit', 'Vehicles', 'Alerts', 'Parking', 'Cars', 'Cycling'
    Around = 'Waste', 'Nearby', 'Air', 'Microclimate'
}
$sections = @($pages.Values | ForEach-Object { $_ })
# Sekce, kde jde o minuty, se obnovují s odjezdy; ostatním stačí jednou za deset minut.
$live = 'Transit', 'Vehicles'
$allEvery = [TimeSpan]::FromMinutes(10)
# Sekce, která se nespojila, to zkusí znovu dřív než za deset minut.
$retryEvery = [TimeSpan]::FromSeconds(30)

# Číselné volby: nejmenší a největší povolená hodnota. Výchozí hodnoty jsou v $defaultOptions (Golemio.ps1),
# v nastavení má každá pole <volba>Box.
$limits = [ordered]@{
    StopsRange = 100, 2000
    WasteRange = 100, 2000
    ParkingRange = 200, 5000
    Departures = 3, 30
    Refresh = 15, 600
}

$state = @{
    # Uložené nastavení: @{ Token; Name; Latitude; Longitude; Options }, kde Options jsou číselné volby
    # a Hidden = sekce, které uživatel v přehledu nechce.
    Saved = $null
    Trial = $false         # přehled s ukázkovými daty, nic se neukládá
    Generation = 0         # zvýší se při změně místa; výsledky starších úloh se zahodí
    Stops = $null          # zastávky v okolí; hledají se jen jednou, je to nejdražší dotaz
    Finished = @{}         # sekce, které se od změny místa aspoň jednou dočetly
    Updated = $null
    Manual = $false        # načítání, o které si řekl uživatel; jen to se v záhlaví ohlašuje
    Finding = $false       # běží hledání adresy
    Found = $null          # naposledy nalezená adresa; Enter v poli s ní ukládá, místo aby hledal znovu
    Page = $null           # otevřená záložka; načítají a obnovují se jen její sekce
    Due = @{}              # sekce -> kdy se má znovu načíst (chybí = hned, jak bude vidět)
    District = ''          # městská část, ve které místo leží
    ShotDue = $null
}

function Test-Demo { $Demo -or $state.Trial }
function Get-Place { if ($state.Trial) { $demoPlace } else { $state.Saved } }

function Get-DefaultOptions {
    $options = @{ Hidden = @() }
    foreach ($name in $limits.Keys) { $options[$name] = $defaultOptions[$name] }
    $options
}
# Ukázka z tlačítka běží vždy s výchozími volbami, ať vypadá pro každého stejně.
function Get-Options { if ($state.Trial -or -not $state.Saved) { Get-DefaultOptions } else { $state.Saved.Options } }
function Get-Sections {
    $hidden = @((Get-Options).Hidden)
    $sections | Where-Object { $_ -notin $hidden }
}
function Get-TransitEvery { [TimeSpan]::FromSeconds((Get-Options).Refresh) }

# Co není číslo, se změní na výchozí hodnotu; číslo mimo meze na nejbližší povolené.
function ConvertTo-Option([string]$name, $value) {
    $number = 0
    if (-not [int]::TryParse("$value", [ref]$number)) { return $defaultOptions[$name] }
    [Math]::Max($limits[$name][0], [Math]::Min($limits[$name][1], $number))
}

# Všechny úlohy sdílejí jednu frontu časů odeslaných dotazů, podle které Golemio.ps1 hlídá limit API,
# a jednu paměť číselníků, ať si je každé vlákno nestahuje znovu.
$limiter = New-Object System.Collections.Queue
$cache = [hashtable]::Synchronized(@{})
function Get-Context {
    if (Test-Demo) { @{ Token = ''; Demo = $demoDirectory; Cache = $cache; Options = Get-Options } }
    else { @{ Token = $state.Saved.Token; Demo = $null; Limiter = $limiter; Cache = $cache; Options = Get-Options } }
}

# ---- Nastavení na disku ----
# Jediné, co si aplikace pamatuje. Klíč šifruje DPAPI, takže ho přečte jen stejný uživatel na stejném počítači.

function Read-Settings {
    try {
        $saved = [IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $token = [Net.NetworkCredential]::new('', (ConvertTo-SecureString $saved.token)).Password
        if ($token -and $null -ne $saved.latitude -and $null -ne $saved.longitude) {
            # Volby mohou chybět (soubor ze starší verze) nebo být přepsané ručně; ConvertTo-Option si poradí s obojím.
            $options = @{ Hidden = @(@($saved.options.hidden) | Where-Object { $_ -in $sections }) }
            foreach ($name in $limits.Keys) { $options[$name] = ConvertTo-Option $name $saved.options.$name }
            return @{
                Token = $token
                Name = if ($saved.place) { [string]$saved.place } else { $unnamed }
                Latitude = [double]$saved.latitude
                Longitude = [double]$saved.longitude
                Options = $options
            }
        }
    } catch { }   # Chybějící, poškozený nebo cizí soubor = první spuštění.
}

function Save-Settings($settings) {
    $null = New-Item -ItemType Directory -Force (Split-Path $SettingsPath)
    # V souboru jsou jména malým písmenem jako ostatní klíče: StopsRange -> stopsRange.
    $options = [ordered]@{}
    foreach ($name in $limits.Keys) { $options[$name.Substring(0, 1).ToLower() + $name.Substring(1)] = $settings.Options[$name] }
    $options.hidden = @($settings.Options.Hidden)
    $json = [ordered]@{
        token = ConvertTo-SecureString $settings.Token -AsPlainText -Force | ConvertFrom-SecureString
        place = $settings.Name
        latitude = $settings.Latitude
        longitude = $settings.Longitude
        options = $options
    } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($SettingsPath, $json, [Text.UTF8Encoding]::new($false))
}

# ---- Úlohy na pozadí ----
# Dotazy na síť nesmí běžet ve vlákně okna, jinak by zamrzlo. Každá úloha si v jiném vlákně načte
# Golemio.ps1, zavolá jednu jeho funkci a vrátí @{ Ok; Data } nebo @{ Ok; Kind; Message }.

$worker = {
    param($library, $command, $arguments)
    $ErrorActionPreference = 'Stop'
    try {
        . $library
        $data = & $command @arguments
        @{ Ok = $true; Data = $data }
    } catch {
        $kind = [string]$_.Exception.Data['Kind']
        # Chyby bez druhu nejsou ze sítě, ale z našeho kódu; ať je to z hlášky poznat.
        $message = if ($kind) { $_.Exception.Message } else { "Tohle se nepovedlo zpracovat: $($_.Exception.Message)" }
        @{ Ok = $false; Kind = $kind; Message = $message }
    }
}.ToString()

$pool = [RunspaceFactory]::CreateRunspacePool(1, 8)
$pool.Open()
$jobs = New-Object System.Collections.ArrayList

# $done je jméno funkce, která dostane úlohu a její výsledek. Jméno, ne blok: uzávěr by neviděl funkce skriptu.
function Start-Work([string]$key, [string]$command, $arguments, [string]$done, $tag) {
    $shell = [PowerShell]::Create()
    $shell.RunspacePool = $pool
    $null = $shell.AddScript($worker).AddArgument($library).AddArgument($command).AddArgument($arguments)
    $null = $jobs.Add(@{
        Key = $key; Done = $done; Tag = $tag; Generation = $state.Generation
        Shell = $shell; Handle = $shell.BeginInvoke()
    })
}

function Complete-Work {
    foreach ($job in @($jobs | Where-Object { $_.Handle.IsCompleted })) {
        $jobs.Remove($job)
        $result = $null
        try { $result = @($job.Shell.EndInvoke($job.Handle))[0] }
        catch { $result = @{ Ok = $false; Kind = ''; Message = "Úloha na pozadí spadla: $($_.Exception.Message)" } }
        finally { $job.Shell.Dispose() }
        if (-not $result) { $result = @{ Ok = $false; Kind = ''; Message = 'Úloha na pozadí nic nevrátila.' } }
        & $job.Done $job $result
    }
}

# ---- Přehled ----

function Format-Coordinate([double]$value) { [string]::Format($invariant, '{0:0.#####}', $value) }

function Show-View([string]$name) {
    foreach ($view in 'SetupView', 'DashboardView') {
        $ui[$view].Visibility = if ($view -eq $name) { 'Visible' } else { 'Hidden' }
        $ui[$view].IsEnabled = $view -eq $name
    }
}

# Stav sekce místo dat: načítání, prázdno nebo chyba.
function Show-State([string]$name, [string]$text, [switch]$IsError) {
    $ui["${name}State"].Text = $text
    $ui["${name}State"].Foreground = $window.FindResource($(if ($IsError) { 'Danger' } else { 'Muted' }))
    $ui["${name}State"].Visibility = 'Visible'
    $ui["${name}Body"].Visibility = 'Collapsed'
}

function Reset-Sections {
    $state.Generation++
    $state.Stops = $null
    $state.Finished = @{}
    $state.Due = @{}
    $state.Updated = $null
    $state.District = ''
    foreach ($name in $sections) {
        $ui["${name}Meta"].Text = ''
        $ui["${name}Body"].DataContext = $null
        Show-State $name $(if ($name -eq 'Transit') { 'Hledám zastávky v okolí…' } else { 'Načítám…' })
    }
}

# Zapnuté sekce jedné záložky.
function Get-PageSections([string]$page) {
    $shown = @(Get-Sections)
    @($pages[$page] | Where-Object { $_ -in $shown })
}

function Start-Section([string]$name) {
    # Termín dalšího načtení se posune hned, ať se sekce nespouští při každém tiknutí časovače.
    $state.Due[$name] = [DateTime]::UtcNow + $(if ($name -in $live) { Get-TransitEvery } else { $allEvery })
    $generation = $state.Generation
    # Předchozí načítání téže sekce ještě běží.
    if ($jobs | Where-Object { $_.Key -eq $name -and $_.Generation -eq $generation }) { return }

    $place = Get-Place
    $arguments = @((Get-Context), $place.Latitude, $place.Longitude)
    if ($name -eq 'Transit') { $arguments += , $state.Stops }
    Start-Work $name "Get-$name" $arguments 'Complete-Section'
}

# Načte, co je na otevřené záložce na řadě. Co vidět není, se nestahuje: šetří to limit API.
function Start-Due {
    if (-not $state.Page) { return }
    $now = [DateTime]::UtcNow
    foreach ($name in @(Get-PageSections $state.Page)) {
        if (-not $state.Due.ContainsKey($name) -or $now -ge $state.Due[$name]) { Start-Section $name }
    }
}

function Complete-Section($job, $result) {
    if ($job.Generation -ne $state.Generation) { return }

    $name = $job.Key
    $state.Finished[$name] = $true
    if (-not $result.Ok) {
        # Při chybě data mizí: starý odjezd nebo obsazenost by vypadaly jako aktuální.
        Show-State $name $result.Message -IsError
        # Výpadek spojení bývá chvilkový, tak se to zkusí brzy znovu. Klíč, který k datům nesmí, se sám nespraví.
        $retry = [DateTime]::UtcNow + $retryEvery
        if ($result.Kind -notin 'Unauthorized', 'Forbidden', 'NotFound' -and $state.Due[$name] -gt $retry) { $state.Due[$name] = $retry }
        return
    }

    $data = $result.Data
    if ($name -eq 'Transit') { $state.Stops = @($data.Stops) }
    $state.Updated = [DateTime]::Now
    $ui["${name}Meta"].Text = [string]$data.Meta
    if ($data.Empty) { Show-State $name $data.Empty; return }

    $ui["${name}Body"].DataContext = $data
    $ui["${name}State"].Visibility = 'Collapsed'
    $ui["${name}Body"].Visibility = 'Visible'
}

# Obnovení, o které si řekl uživatel (tlačítko, F5): všechno na otevřené záložce hned.
function Update-Sections {
    $state.Manual = $true
    foreach ($name in @(Get-PageSections $state.Page)) { Start-Section $name }
}

function Show-Page([string]$page) {
    $state.Page = $page
    foreach ($name in $pages.Keys) {
        $ui["${name}Page"].Visibility = if ($name -eq $page) { 'Visible' } else { 'Collapsed' }
        $ui["${name}Tab"].IsChecked = $name -eq $page
    }
    $ui.DashboardScroll.ScrollToTop()
    if ($ui.DashboardView.IsEnabled) { Start-Due }
}

# Schová karty, které uživatel vypnul, sloupce, ve kterých žádná nezbyla (ať po nich nezůstane díra),
# a záložky, na kterých by nebylo nic.
function Update-Layout {
    $shown = @(Get-Sections)
    foreach ($name in $sections) {
        $ui["${name}Card"].Visibility = if ($name -in $shown) { 'Visible' } else { 'Collapsed' }
    }

    $open = @()
    foreach ($page in $pages.Keys) {
        # V mřížce jsou sudé sloupce karty a liché mezery mezi nimi.
        $columns = $ui["${page}Page"].ColumnDefinitions
        $used = 0
        foreach ($index in 0..2) {
            $any = @($ui["${page}Column$($index + 1)"].Children | Where-Object { $_.Visibility -eq 'Visible' }).Count -gt 0
            $columns[$index * 2].Width = [Windows.GridLength]::new($(if ($any) { $columnWeights[$page][$index] } else { 0 }), 'Star')
            if ($index -gt 0) {
                $columns[$index * 2 - 1].Width = [Windows.GridLength]::new($(if ($any -and $used -gt 0) { $columnGap } else { 0 }))
            }
            if ($any) { $used++ }
        }
        # Jeden nebo dva sloupce přes celé okno by byly zbytečně široké.
        $ui["${page}Page"].MaxWidth = if ($used -eq 3) { [double]::PositiveInfinity } else { 560 * $used }
        $ui["${page}Tab"].Visibility = if ($used) { 'Visible' } else { 'Collapsed' }
        if ($used) { $open += $page }
    }
    # S jedinou záložkou není mezi čím přepínat.
    $ui.Tabs.Visibility = if ($open.Count -gt 1) { 'Visible' } else { 'Collapsed' }
    Show-Page $(if ($state.Page -in $open) { $state.Page } else { $open[0] })
}

function Update-Header {
    $busy = $state.Manual -and @($jobs | Where-Object { $_.Done -eq 'Complete-Section' }).Count -gt 0
    if (-not $busy) { $state.Manual = $false }
    $ui.RefreshButton.IsEnabled = -not $busy
    $ui.UpdatedText.Text =
        if ($busy) { 'načítám…' }
        elseif ($state.Updated) { 'aktualizováno ' + $state.Updated.ToString('H\:mm') }
        else { '' }
}

function Update-Place {
    $place = Get-Place
    $ui.PlaceText.Text = $place.Name
    $ui.CoordinatesText.Text = ((Format-Coordinate $place.Latitude) + ', ' + (Format-Coordinate $place.Longitude)), $state.District -ne '' -join ' · '
}

# Městská část je jen do záhlaví; když se nezjistí, zůstanou tam samotné souřadnice.
function Complete-District($job, $result) {
    if ($job.Generation -ne $state.Generation -or -not $result.Ok) { return }
    $state.District = [string]$result.Data
    Update-Place
}

function Show-Dashboard([switch]$Reload) {
    $ui.DemoBadge.Visibility = if (Test-Demo) { 'Visible' } else { 'Collapsed' }
    Show-View 'DashboardView'
    if ($Reload) {
        Reset-Sections
        $state.Manual = $true
        $place = Get-Place
        Start-Work 'District' 'Get-District' @((Get-Context), $place.Latitude, $place.Longitude) 'Complete-District'
    }
    Update-Place
    # Update-Layout otevře záložku a tím spustí načítání toho, co je na ní na řadě.
    Update-Layout
}

# ---- Nastavení v okně ----

function Set-SetupStatus([string]$text, [switch]$IsError) {
    $ui.SetupStatus.Text = $text
    $ui.SetupStatus.Foreground = $window.FindResource($(if ($IsError) { 'Danger' } else { 'Muted' }))
}

function Show-Setup {
    $saved = $state.Saved
    $ui.TokenBox.Password = if ($saved) { $saved.Token } else { '' }
    $ui.AddressBox.Text = if ($saved -and $saved.Name -ne $unnamed) { $saved.Name } else { '' }
    $ui.LatitudeBox.Text = if ($saved) { Format-Coordinate $saved.Latitude } else { '' }
    $ui.LongitudeBox.Text = if ($saved) { Format-Coordinate $saved.Longitude } else { '' }
    $options = if ($saved) { $saved.Options } else { Get-DefaultOptions }
    foreach ($name in $limits.Keys) { $ui["${name}Box"].Text = "$($options[$name])" }
    foreach ($name in $sections) { $ui["${name}Chip"].IsChecked = $name -notin $options.Hidden }
    $ui.ResultsList.ItemsSource = $null
    $ui.ResultsList.Visibility = 'Collapsed'
    # Uložená adresa už souřadnice má: Enter v poli ji uloží, hledat se začne, až ji uživatel přepíše.
    $state.Found = if ($ui.AddressBox.Text) { $ui.AddressBox.Text } else { $null }
    Set-SetupStatus ''

    # Je-li se kam vrátit, nabízí se návrat; jinak ukázka, ať jde aplikace zkusit i bez klíče.
    $canReturn = $saved -or $state.Trial
    $ui.BackButton.Visibility = if ($canReturn) { 'Visible' } else { 'Collapsed' }
    $ui.DemoButton.Visibility = if ($canReturn) { 'Collapsed' } else { 'Visible' }

    Show-View 'SetupView'
    $null = $(if ($ui.TokenBox.Password) { $ui.AddressBox } else { $ui.TokenBox }).Focus()
}

# "50,0753", "50.0753" i "50.0753°"; nic nevrátí, když to není číslo v rozsahu.
function Read-Coordinate([string]$text, [double]$limit) {
    $value = 0.0
    $text = $text.Replace(',', '.') -replace '[°\s]'
    if ([double]::TryParse($text, 'Float', $invariant, [ref]$value) -and [Math]::Abs($value) -le $limit) { $value }
}

# S parametrem -Demo se neptáme sítě ani tady, aby šlo nastavení projít v testech.
function Get-SetupContext([string]$token) {
    @{ Token = $token; Demo = $(if ($Demo) { $demoDirectory }); Limiter = $limiter }
}

function Find-Place {
    $text = $ui.AddressBox.Text.Trim()
    if (-not $text) {
        Set-SetupStatus 'Napiš adresu, třeba „Korunní 2, Praha“.' -IsError
        return
    }
    # Tlačítko se během hledání nevypíná: vypnutím by přišlo o fokus a klávesnice by pak v okně nedělala nic.
    if ($state.Finding) { return }

    $state.Finding = $true
    Set-SetupStatus 'Hledám…'
    Start-Work 'Find' 'Find-Address' @((Get-SetupContext ''), $text) 'Complete-Find' $text
}

function Complete-Find($job, $result) {
    $state.Finding = $false
    if (-not $result.Ok) { Set-SetupStatus $result.Message -IsError; return }

    $found = @($result.Data | Where-Object { $_ })
    $ui.ResultsList.ItemsSource = $found
    $ui.ResultsList.Visibility = if ($found) { 'Visible' } else { 'Collapsed' }
    if (-not $found) {
        Set-SetupStatus 'Nic jsem nenašel. Zkus adresu napsat přesněji.' -IsError
        return
    }
    # První výsledek bývá ten pravý, tak se rovnou vybere (Select-Place vyplní pole adresy i souřadnice).
    $ui.ResultsList.SelectedIndex = 0
    # Po kliknutí na Najít by Enter na tlačítku hledal pořád dokola; z pole adresy se jím pokračuje dál.
    if ($ui.FindButton.IsFocused) { $null = $ui.AddressBox.Focus() }
    Set-SetupStatus $(if ($found.Count -gt 1) { 'Vybral jsem první výsledek. Jestli nesedí, klikni na jiný.' } else { 'Adresa nalezena. Enter nebo tlačítko níž ji uloží.' })
}

# Vybraná adresa se propíše do pole (uloží se jako jméno místa) a do souřadnic.
function Select-Place {
    $picked = $ui.ResultsList.SelectedItem
    if (-not $picked) { return }
    $ui.LatitudeBox.Text = Format-Coordinate $picked.Latitude
    $ui.LongitudeBox.Text = Format-Coordinate $picked.Longitude
    $ui.AddressBox.Text = $picked.Label
    $ui.AddressBox.CaretIndex = $picked.Label.Length
    # Další Enter v poli s touhle adresou už nehledá znovu, ale ukládá.
    $state.Found = $picked.Label
}

function Save-Setup {
    if (-not $ui.SetupView.IsEnabled) { return }

    $token = $ui.TokenBox.Password.Trim()
    if (-not $token) {
        Set-SetupStatus 'Vlož klíč ke Golemio API.' -IsError
        $null = $ui.TokenBox.Focus()
        return
    }
    $latitude = Read-Coordinate $ui.LatitudeBox.Text 90
    $longitude = Read-Coordinate $ui.LongitudeBox.Text 180
    if ($null -eq $latitude -or $null -eq $longitude) {
        Set-SetupStatus 'Najdi adresu, nebo vyplň souřadnice (třeba 50,0753 a 14,4379).' -IsError
        return
    }

    $options = @{ Hidden = @($sections | Where-Object { -not $ui["${_}Chip"].IsChecked }) }
    if ($options.Hidden.Count -eq $sections.Count) {
        Set-SetupStatus 'Nech zapnutou aspoň jednu kartu.' -IsError
        return
    }
    foreach ($name in $limits.Keys) {
        $options[$name] = ConvertTo-Option $name $ui["${name}Box"].Text
        # Ať je ve formuláři vidět, co se opravdu uloží.
        $ui["${name}Box"].Text = "$($options[$name])"
    }

    $name = $ui.AddressBox.Text.Trim()
    $settings = @{
        Token = $token
        Name = if ($name) { $name } else { $unnamed }
        Latitude = $latitude
        Longitude = $longitude
        Options = $options
    }
    # Než klíč ověříme, formulář zamrzne, aby se mezitím nedalo odejít jinam.
    $ui.SetupView.IsEnabled = $false
    Set-SetupStatus 'Ověřuju klíč…'
    Start-Work 'Save' 'Test-Token' @(, (Get-SetupContext $token)) 'Complete-Save' $settings
}

function Complete-Save($job, $result) {
    $ui.SetupView.IsEnabled = $true
    if (-not $result.Ok) {
        $text = if ($result.Kind -eq 'Unauthorized') { 'Golemio tenhle klíč odmítlo. Zkontroluj, že je zkopírovaný celý.' } else { $result.Message }
        Set-SetupStatus $text -IsError
        # Vypnutý formulář přišel o fokus; bez tohohle by po neúspěchu klávesnice nedělala nic.
        $null = $(if ($result.Kind -eq 'Unauthorized') { $ui.TokenBox } else { $ui.SaveButton }).Focus()
        return
    }
    try { Save-Settings $job.Tag }
    catch {
        Set-SetupStatus "Nastavení se nepodařilo uložit: $($_.Exception.Message)" -IsError
        return
    }
    $state.Saved = $job.Tag
    $state.Trial = $false
    Show-Dashboard -Reload
}

# ---- Obrázek okna ----

function Save-Screenshot([string]$path) {
    $root = $window.Content
    $scale = [Windows.Media.VisualTreeHelper]::GetDpi($root).DpiScaleX
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int][Math]::Ceiling($root.ActualWidth * $scale), [int][Math]::Ceiling($root.ActualHeight * $scale),
        96 * $scale, 96 * $scale, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)

    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

# ---- Okno ----

try {
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'GolemWatch.xaml')))
    if (Test-Path -LiteralPath $icon) { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icon) }

    $ui = @{}
    'SetupView', 'TokenBox', 'KeyLink', 'AddressBox', 'FindButton', 'ResultsList', 'LatitudeBox', 'LongitudeBox',
    'LimitsHint', 'SaveButton', 'SetupStatus', 'BackButton', 'DemoButton', 'VersionText',
    'DashboardView', 'PlaceText', 'CoordinatesText', 'DemoBadge', 'UpdatedText', 'RefreshButton', 'SettingsButton',
    'DashboardScroll', 'Tabs' | ForEach-Object { $ui[$_] = $window.FindName($_) }
    foreach ($name in $sections) {
        'Card', 'Meta', 'State', 'Body', 'Chip' | ForEach-Object { $ui["$name$_"] = $window.FindName("$name$_") }
    }
    foreach ($name in $limits.Keys) { $ui["${name}Box"] = $window.FindName("${name}Box") }
    # Šířky sloupců záložek jsou napsané v XAML; odsud se berou, když se sloupec schová a zase ukáže.
    $columnWeights = @{}
    foreach ($name in $pages.Keys) {
        'Tab', 'Page', 'Column1', 'Column2', 'Column3' | ForEach-Object { $ui["$name$_"] = $window.FindName("$name$_") }
        $definitions = $ui["${name}Page"].ColumnDefinitions
        $columnWeights[$name] = @(0, 2, 4 | ForEach-Object { $definitions[$_].Width.Value })
        $columnGap = $definitions[1].Width.Value
    }
    $missing = @($ui.Keys | Where-Object { $null -eq $ui[$_] } | Sort-Object)
    if ($missing) { throw "V GolemWatch.xaml chybí prvky: $($missing -join ', ')" }

    # Na malém displeji by okno ve výchozí velikosti přečnívalo přes okraj obrazovky.
    $area = [Windows.SystemParameters]::WorkArea
    $window.Width = [Math]::Min($window.Width, $area.Width)
    $window.Height = [Math]::Min($window.Height, $area.Height)
    $window.MinWidth = [Math]::Min($window.MinWidth, $window.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight, $window.Height)

    $window.Add_SourceInitialized({
        if (-not $native) { return }
        $hwnd = [Windows.Interop.WindowInteropHelper]::new($window).Handle
        # 20 = tmavý režim, 35 = barva titulku, 34 = barva rámečku; barva je #11141B jako COLORREF (0x00BBGGRR).
        # Starší Windows volání jen odmítnou a titulek zůstane výchozí.
        foreach ($attribute in @(20, 1), @(35, 0x001B1411), @(34, 0x001B1411)) {
            $value = $attribute[1]
            $null = $native::DwmSetWindowAttribute($hwnd, $attribute[0], [ref]$value, 4)
        }
    })

    # ---- Nastavení ----

    $ui.KeyLink.Add_RequestNavigate({
        param($link, $e)
        Start-Process $e.Uri.AbsoluteUri
        $e.Handled = $true
    })

    $ui.FindButton.Add_Click({ Find-Place })
    $ui.AddressBox.Add_KeyDown({
        param($box, $e)
        if ($e.Key -ne 'Return') { return }
        # Adresa, která se už našla, se Enterem uloží; nová nebo změněná se nejdřív hledá.
        if ($state.Found -and $ui.AddressBox.Text.Trim() -eq $state.Found) { Save-Setup } else { Find-Place }
        $e.Handled = $true
    })
    $ui.ResultsList.Add_KeyDown({
        param($list, $e)
        if ($e.Key -ne 'Return') { return }
        Save-Setup
        $e.Handled = $true
    })

    $ui.ResultsList.Add_SelectionChanged({ Select-Place })
    # Klik na řádek, který už vybraný je, výběr nezmění; adresu má vyplnit i tak (třeba po přepsání pole).
    $ui.ResultsList.Add_PreviewMouseLeftButtonUp({ Select-Place })
    # Šipkami se dá mezi nalezenými adresami vybírat rovnou z pole, bez myši.
    $ui.AddressBox.Add_PreviewKeyDown({
        param($box, $e)
        $step = switch ("$($e.Key)") { 'Down' { 1 } 'Up' { -1 } default { 0 } }
        $count = $ui.ResultsList.Items.Count
        if (-not $step -or -not $count -or $ui.ResultsList.Visibility -ne 'Visible') { return }
        $ui.ResultsList.SelectedIndex = [Math]::Max(0, [Math]::Min($count - 1, $ui.ResultsList.SelectedIndex + $step))
        $ui.ResultsList.ScrollIntoView($ui.ResultsList.SelectedItem)
        $e.Handled = $true
    })

    # Pole s čísly berou jen číslice a po opuštění se srovnají do povolených mezí.
    $numberBoxes = @($limits.Keys | ForEach-Object { $ui["${_}Box"] })
    foreach ($name in $limits.Keys) {
        $ui["${name}Box"].Tag = $name
        $ui["${name}Box"].Add_TextChanged({
            param($box)
            $digits = $box.Text -replace '[^0-9]'
            if ($digits -eq $box.Text) { return }
            $box.Text = $digits
            $box.CaretIndex = $digits.Length
        })
        $ui["${name}Box"].Add_LostKeyboardFocus({ param($box) $box.Text = "$(ConvertTo-Option $box.Tag $box.Text)" })
    }
    $ui.LimitsHint.Text = 'Povolené hodnoty: zastávky {0} m, tříděný odpad {1} m, parkoviště {2} m, odjezdů {3}, obnovování po {4} s. Jiné číslo se upraví na nejbližší povolené.' -f
        @($limits.Values | ForEach-Object { $_ -join '–' })

    $ui.SaveButton.Add_Click({ Save-Setup })
    foreach ($box in @($ui.TokenBox, $ui.LatitudeBox, $ui.LongitudeBox) + $numberBoxes) {
        $box.Add_KeyDown({
            param($box, $e)
            if ($e.Key -ne 'Return') { return }
            Save-Setup
            $e.Handled = $true
        })
    }

    $ui.BackButton.Add_Click({ Show-Dashboard })
    $ui.DemoButton.Add_Click({
        $state.Trial = $true
        Show-Dashboard -Reload
    })

    # ---- Přehled ----

    $ui.RefreshButton.Add_Click({ Update-Sections })
    $ui.SettingsButton.Add_Click({ Show-Setup })
    foreach ($name in $pages.Keys) {
        $ui["${name}Tab"].Tag = $name
        # Show-Page záložku sama zaškrtává; bez podmínky by se volala dvakrát.
        $ui["${name}Tab"].Add_Checked({ param($tab) if ($state.Page -ne $tab.Tag) { Show-Page $tab.Tag } })
    }
    $window.Add_KeyDown({
        param($source, $e)
        if ($e.Key -ne 'F5' -or -not $ui.DashboardView.IsEnabled) { return }
        Update-Sections
        $e.Handled = $true
    })

    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        Complete-Work
        Update-Header

        if ($Screenshot) {
            # Nastavení je hotové hned, přehled až se dočtou sekce otevřené záložky; pak ještě chvilka na vykreslení.
            $ready = $ui.SetupView.IsEnabled -or @(Get-PageSections $state.Page | Where-Object { -not $state.Finished[$_] }).Count -eq 0
            if ($ready -and -not $state.ShotDue) {
                # Okno se natáhne, aby byl na obrázku celý přehled, ne jen to, co se vejde bez posouvání.
                $window.UpdateLayout()
                $hidden = $ui.DashboardScroll.ExtentHeight - $ui.DashboardScroll.ViewportHeight
                if ($ui.DashboardView.IsEnabled -and $hidden -gt 0) { $window.Height += $hidden }
                $state.ShotDue = [DateTime]::UtcNow.AddMilliseconds(600)
            }
            elseif ($state.ShotDue -and [DateTime]::UtcNow -ge $state.ShotDue) {
                Save-Screenshot $Screenshot
                $window.Close()
                return
            }
        }

        # Schované nebo minimalizované okno nic nestahuje; po návratu se obnoví hned.
        if (-not $ui.DashboardView.IsEnabled -or $window.WindowState -eq 'Minimized') { return }
        Start-Due
    })

    $ui.VersionText.Text = "GolemWatch $version"
    if ($Page -in $pages.Keys) { $state.Page = $Page }

    $state.Saved = Read-Settings
    if ($state.Saved) { Show-Dashboard -Reload }
    elseif ($Demo) {
        $state.Trial = $true
        Show-Dashboard -Reload
    }
    else { Show-Setup }

    $timer.Start()
    $null = $window.ShowDialog()
    $timer.Stop()
    # Rozdělané dotazy už nikoho nezajímají; na jejich dokončení se nečeká.
    foreach ($job in $jobs) { $null = $job.Shell.BeginStop($null, $null) }
}
catch {
    # Konzole je schovaná, takže chybu jinak nikdo neuvidí.
    $null = [Windows.MessageBox]::Show("$_", 'GolemWatch', 'OK', 'Error')
}
