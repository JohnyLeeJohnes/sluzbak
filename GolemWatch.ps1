# GolemWatch: přehled pražských dat z Golemio API kolem jednoho místa.
# Okno je popsané v GolemWatch.xaml, data čte Golemio.ps1 na pozadí.
#   GolemWatch.ps1                         spustí aplikaci
#   GolemWatch.ps1 -Install                vytvoří zástupce s ikonou v nabídce Start, na ploše a ve složce s aplikací
#   GolemWatch.ps1 -Demo                   místo sítě čte ukázková data ze složky demo (bez klíče i bez internetu)
#   GolemWatch.ps1 -SettingsPath <soubor>  nastavení jinde než v %APPDATA% (pro testy)
#   GolemWatch.ps1 -Screenshot <png>       po načtení uloží obrázek okna a skončí (obrázky do README)
param([switch]$Install, [switch]$Demo, [string]$SettingsPath, [string]$Screenshot)

$ErrorActionPreference = 'Stop'
$icon = Join-Path $PSScriptRoot 'assets\golemwatch.ico'
$library = Join-Path $PSScriptRoot 'Golemio.ps1'
$demoDirectory = Join-Path $PSScriptRoot 'demo'

if ($Install) {
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

# Ke každé sekci patří funkce Get-<sekce> v Golemio.ps1 a prvky <sekce>Meta, <sekce>State a <sekce>Body v okně.
$sections = 'Transit', 'Nearby', 'Waste', 'Air', 'Microclimate', 'Parking'
$transitEvery = [TimeSpan]::FromSeconds(30)
$allEvery = [TimeSpan]::FromMinutes(10)

$state = @{
    Saved = $null          # uložené nastavení: @{ Token; Name; Latitude; Longitude }
    Trial = $false         # přehled s ukázkovými daty, nic se neukládá
    Generation = 0         # zvýší se při změně místa; výsledky starších úloh se zahodí
    Stops = $null          # zastávky v okolí; hledají se jen jednou, je to nejdražší dotaz
    Finished = @{}         # sekce, které se od změny místa aspoň jednou dočetly
    Updated = $null
    Manual = $false        # načítání, o které si řekl uživatel; jen to se v záhlaví ohlašuje
    TransitDue = [DateTime]::MaxValue
    AllDue = [DateTime]::MaxValue
    ShotDue = $null
}

function Test-Demo { $Demo -or $state.Trial }
function Get-Place { if ($state.Trial) { $demoPlace } else { $state.Saved } }
# Všechny úlohy sdílejí jednu frontu časů odeslaných dotazů, podle které Golemio.ps1 hlídá limit API.
$limiter = New-Object System.Collections.Queue
function Get-Context {
    if (Test-Demo) { @{ Token = ''; Demo = $demoDirectory } }
    else { @{ Token = $state.Saved.Token; Demo = $null; Limiter = $limiter } }
}

# ---- Nastavení na disku ----
# Jediné, co si aplikace pamatuje. Klíč šifruje DPAPI, takže ho přečte jen stejný uživatel na stejném počítači.

function Read-Settings {
    try {
        $saved = [IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $token = [Net.NetworkCredential]::new('', (ConvertTo-SecureString $saved.token)).Password
        if ($token -and $null -ne $saved.latitude -and $null -ne $saved.longitude) {
            return @{
                Token = $token
                Name = if ($saved.place) { [string]$saved.place } else { $unnamed }
                Latitude = [double]$saved.latitude
                Longitude = [double]$saved.longitude
            }
        }
    } catch { }   # Chybějící, poškozený nebo cizí soubor = první spuštění.
}

function Save-Settings($settings) {
    $null = New-Item -ItemType Directory -Force (Split-Path $SettingsPath)
    $json = [ordered]@{
        token = ConvertTo-SecureString $settings.Token -AsPlainText -Force | ConvertFrom-SecureString
        place = $settings.Name
        latitude = $settings.Latitude
        longitude = $settings.Longitude
    } | ConvertTo-Json
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
    $state.Updated = $null
    foreach ($name in $sections) {
        $ui["${name}Meta"].Text = ''
        $ui["${name}Body"].DataContext = $null
        Show-State $name $(if ($name -eq 'Transit') { 'Hledám zastávky v okolí…' } else { 'Načítám…' })
    }
}

function Start-Section([string]$name) {
    $generation = $state.Generation
    # Předchozí načítání téže sekce ještě běží.
    if ($jobs | Where-Object { $_.Key -eq $name -and $_.Generation -eq $generation }) { return }

    $place = Get-Place
    $arguments = @((Get-Context), $place.Latitude, $place.Longitude)
    if ($name -eq 'Transit') { $arguments += , $state.Stops }
    Start-Work $name "Get-$name" $arguments 'Complete-Section'
}

function Complete-Section($job, $result) {
    if ($job.Generation -ne $state.Generation) { return }

    $name = $job.Key
    $state.Finished[$name] = $true
    # Při chybě data mizí: starý odjezd nebo obsazenost by vypadaly jako aktuální.
    if (-not $result.Ok) { Show-State $name $result.Message -IsError; return }

    $data = $result.Data
    if ($name -eq 'Transit') { $state.Stops = @($data.Stops) }
    $state.Updated = [DateTime]::Now
    $ui["${name}Meta"].Text = [string]$data.Meta
    if ($data.Empty) { Show-State $name $data.Empty; return }

    $ui["${name}Body"].DataContext = $data
    $ui["${name}State"].Visibility = 'Collapsed'
    $ui["${name}Body"].Visibility = 'Visible'
}

function Update-Sections([switch]$Manual) {
    if ($Manual) { $state.Manual = $true }
    $now = [DateTime]::UtcNow
    $state.AllDue = $now + $allEvery
    $state.TransitDue = $now + $transitEvery
    foreach ($name in $sections) { Start-Section $name }
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

function Show-Dashboard([switch]$Reload) {
    $place = Get-Place
    $ui.PlaceText.Text = $place.Name
    $ui.CoordinatesText.Text = (Format-Coordinate $place.Latitude) + ', ' + (Format-Coordinate $place.Longitude)
    $ui.DemoBadge.Visibility = if (Test-Demo) { 'Visible' } else { 'Collapsed' }
    Show-View 'DashboardView'
    if ($Reload) {
        Reset-Sections
        Update-Sections -Manual
    }
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
    $ui.ResultsList.ItemsSource = $null
    $ui.ResultsList.Visibility = 'Collapsed'
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
    if (-not $ui.FindButton.IsEnabled) { return }

    $ui.FindButton.IsEnabled = $false
    Set-SetupStatus 'Hledám…'
    Start-Work 'Find' 'Find-Address' @((Get-SetupContext ''), $text) 'Complete-Find'
}

function Complete-Find($job, $result) {
    $ui.FindButton.IsEnabled = $true
    if (-not $result.Ok) { Set-SetupStatus $result.Message -IsError; return }

    $found = @($result.Data | Where-Object { $_ })
    $ui.ResultsList.ItemsSource = $found
    $ui.ResultsList.Visibility = if ($found) { 'Visible' } else { 'Collapsed' }
    if (-not $found) {
        Set-SetupStatus 'Nic jsem nenašel. Zkus adresu napsat přesněji.' -IsError
        return
    }
    # První výsledek bývá ten pravý, tak se rovnou vybere (a tím vyplní souřadnice).
    $ui.ResultsList.SelectedIndex = 0
    Set-SetupStatus $(if ($found.Count -gt 1) { 'Vybral jsem první výsledek. Jestli nesedí, klikni na jiný.' } else { '' })
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

    $name = $ui.AddressBox.Text.Trim()
    $settings = @{
        Token = $token
        Name = if ($name) { $name } else { $unnamed }
        Latitude = $latitude
        Longitude = $longitude
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
    'SaveButton', 'SetupStatus', 'BackButton', 'DemoButton',
    'DashboardView', 'PlaceText', 'CoordinatesText', 'DemoBadge', 'UpdatedText', 'RefreshButton', 'SettingsButton',
    'DashboardScroll' | ForEach-Object { $ui[$_] = $window.FindName($_) }
    foreach ($name in $sections) {
        'Meta', 'State', 'Body' | ForEach-Object { $ui["$name$_"] = $window.FindName("$name$_") }
    }

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
        Find-Place
        $e.Handled = $true
    })

    $ui.ResultsList.Add_SelectionChanged({
        $picked = $ui.ResultsList.SelectedItem
        if (-not $picked) { return }
        $ui.LatitudeBox.Text = Format-Coordinate $picked.Latitude
        $ui.LongitudeBox.Text = Format-Coordinate $picked.Longitude
    })

    $ui.SaveButton.Add_Click({ Save-Setup })
    foreach ($box in $ui.TokenBox, $ui.LatitudeBox, $ui.LongitudeBox) {
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

    $ui.RefreshButton.Add_Click({ Update-Sections -Manual })
    $ui.SettingsButton.Add_Click({ Show-Setup })
    $window.Add_KeyDown({
        param($source, $e)
        if ($e.Key -ne 'F5' -or -not $ui.DashboardView.IsEnabled) { return }
        Update-Sections -Manual
        $e.Handled = $true
    })

    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        Complete-Work
        Update-Header

        if ($Screenshot) {
            # Nastavení je hotové hned, přehled až se dočtou všechny sekce; pak ještě chvilka na vykreslení.
            $ready = $ui.SetupView.IsEnabled -or $state.Finished.Count -eq $sections.Count
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
        $now = [DateTime]::UtcNow
        if ($now -ge $state.AllDue) { Update-Sections }
        elseif ($now -ge $state.TransitDue) {
            $state.TransitDue = $now + $transitEvery
            Start-Section 'Transit'
        }
    })

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
