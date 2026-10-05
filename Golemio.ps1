# Golemio.ps1: čtení dat z Golemio API a hledání adres přes Nominatim.
# Žádné okno: funkce běží na pozadí (GolemWatch.ps1) i v testech (tests/unit.ps1).
# Funkce Get-* vracejí objekty připravené k zobrazení, texty už jsou naformátované.
#
# $context = @{ Token = '...'; Demo = $null; Limiter = $null; Cache = $null; Options = @{} }
# S Demo = cesta ke složce se místo sítě čtou ukázkové soubory (viz Read-Demo).
# Limiter je fronta pro hlídání limitu API (viz Wait-RateLimit), Cache společná paměť číselníků (viz Get-Cached),
# Options volby uživatele (viz $defaultOptions).

Add-Type -AssemblyName System.Net.Http, System.Web.Extensions

# Volby, které si uživatel může změnit v nastavení. Co v $context.Options chybí, platí odsud.
$defaultOptions = @{
    StopsRange = 600      # m, odkud se berou zastávky
    WasteRange = 400      # m, stanoviště tříděného odpadu
    ParkingRange = 1500   # m, parkoviště
    Departures = 12       # kolik odjezdů ukázat
    Refresh = 30          # s, jak často okno obnovuje odjezdy
}

function Get-Option($context, [string]$name) {
    $options = $context.Options
    if ($options -and $null -ne $options[$name]) { $options[$name] } else { $defaultOptions[$name] }
}

$cs = [Globalization.CultureInfo]::GetCultureInfo('cs-CZ')
$invariant = [Globalization.CultureInfo]::InvariantCulture
# Data jsou o Praze, takže časy ukazujeme pražské, ať je počítač nastavený jakkoli.
$pragueZone = [TimeZoneInfo]::FindSystemTimeZoneById('Central Europe Standard Time')

# ---- Chyby ----
# Chyba nese druh (Unauthorized, Forbidden, NotFound, RateLimited, Network, Unexpected) a českou hlášku pro uživatele.

function New-ApiError([string]$kind, [string]$message) {
    $exception = [Exception]::new($message)
    $exception.Data['Kind'] = $kind
    $exception
}

function ConvertTo-ApiError([int]$status) {
    switch ($status) {
        401 { New-ApiError 'Unauthorized' 'Golemio tenhle klíč odmítlo. Zkontroluj ho v nastavení.' }
        403 { New-ApiError 'Forbidden' 'Tvůj klíč k těmhle datům nemá přístup.' }
        404 { New-ApiError 'NotFound' 'Golemio tahle data nenašlo.' }
        429 { New-ApiError 'RateLimited' 'Příliš mnoho dotazů najednou, zkus to za chvíli.' }
        default { New-ApiError 'Unexpected' "Golemio vrátilo chybu $status." }
    }
}

# ---- HTTP a JSON ----

function Format-Invariant($value) {
    if ($value -is [bool]) { return "$value".ToLowerInvariant() }
    [string]::Format($invariant, '{0}', $value)
}

# $query je [ordered]@{}; hodnota $null se vynechá, pole zopakuje klíč (ids[]=a&ids[]=b).
function Format-Query($query) {
    $pairs = @(foreach ($key in @($query.Keys)) {
        foreach ($value in @($query[$key])) {
            if ($null -ne $value) { [Uri]::EscapeDataString($key) + '=' + [Uri]::EscapeDataString((Format-Invariant $value)) }
        }
    })
    if ($pairs) { '?' + ($pairs -join '&') } else { '' }
}

function Format-LatLng([double]$latitude, [double]$longitude) {
    [string]::Format($invariant, '{0:0.######},{1:0.######}', $latitude, $longitude)
}

# ConvertFrom-Json ve Windows PowerShellu neunese odpovědi nad 2 MB (seznam zastávek je větší).
function ConvertFrom-ApiJson([string]$text) {
    if (-not $global:GolemWatchJson) {
        $global:GolemWatchJson = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $global:GolemWatchJson.MaxJsonLength = [int]::MaxValue
    }
    $global:GolemWatchJson.DeserializeObject($text)
}

# Klient žije v globální proměnné, aby ho úlohy na pozadí sdílely a spojení se neotvíralo pokaždé znovu.
function Get-HttpClient {
    if (-not $global:GolemWatchHttp) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # Výchozí dvě spojení na server nestačí: karty se čtou naráz a za stahováním zastávek by ostatní čekaly.
        [Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max([Net.ServicePointManager]::DefaultConnectionLimit, 6)
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AutomaticDecompression = 'GZip, Deflate'
        $global:GolemWatchHttp = New-Object System.Net.Http.HttpClient $handler
        $global:GolemWatchHttp.Timeout = [TimeSpan]::FromSeconds(30)
        # Nominatim vyžaduje, aby se aplikace představila.
        $null = $global:GolemWatchHttp.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'GolemWatch (+https://github.com/JohnyLeeJohnes/GolemWatch)')
    }
    $global:GolemWatchHttp
}

function Invoke-Http([string]$uri, [string]$token, [string]$service) {
    # Druhý pokus spraví spojení, které server mezitím zavřel, i chvilkový výpadek. Čte se jen (GET), takže neuškodí.
    # Pomáhá i u dotazů, na které Golemio poprvé odpovídá přes půl minuty: napodruhé už bývá odpověď hned.
    foreach ($attempt in 1, 2) {
        $request = New-Object System.Net.Http.HttpRequestMessage ([Net.Http.HttpMethod]::Get), $uri
        if ($token) { $null = $request.Headers.TryAddWithoutValidation('X-Access-Token', $token.Trim()) }
        try {
            $response = (Get-HttpClient).SendAsync($request).GetAwaiter().GetResult()
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            break
        } catch {
            if ($attempt -eq 1) { Start-Sleep -Milliseconds 400; continue }
            if ($_.Exception.GetBaseException() -is [OperationCanceledException]) {
                throw (New-ApiError 'Network' "Služba $service neodpověděla včas. Zkus to za chvíli.")
            }
            throw (New-ApiError 'Network' "Nepodařilo se spojit se službou $service. Zkontroluj připojení k internetu.")
        }
    }
    if (-not $response.IsSuccessStatusCode) { throw (ConvertTo-ApiError ([int]$response.StatusCode)) }

    # Dekódujeme sami: Invoke-RestMethod bez charsetu v hlavičce rozbije háčky a čárky.
    try { ConvertFrom-ApiJson ([Text.Encoding]::UTF8.GetString($bytes)) }
    catch { throw (New-ApiError 'Unexpected' "Služba $service poslala odpověď, které nerozumím.") }
}

# Ukázková data: /v2/pid/departureboards -> v2-pid-departureboards.json.
# {{now+5}} se nahradí časem za 5 minut, {{day+1}} zítřejším datem, aby ukázka nikdy nezestárla.
function Read-Demo([string]$directory, [string]$name) {
    $file = Join-Path $directory (($name.Trim('/') -replace '/', '-') + '.json')
    if (-not (Test-Path -LiteralPath $file)) { throw (New-ApiError 'NotFound' "Ukázková data pro $name chybí.") }

    $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    # Půl minuty navíc, aby z {{now+5}} bylo po zaokrouhlení dolů pořád "za 5 min".
    $now = (Get-PragueNow).AddSeconds(30)
    $text = [regex]::Replace($text, '\{\{now([+-]\d+)\}\}', { param($m) $now.AddMinutes([int]$m.Groups[1].Value).ToString('yyyy-MM-ddTHH:mm:sszzz', $invariant) })
    $text = [regex]::Replace($text, '\{\{day([+-]\d+)\}\}', { param($m) $now.AddDays([int]$m.Groups[1].Value).ToString('yyyy-MM-dd', $invariant) })
    ConvertFrom-ApiJson $text
}

# Golemio dovolí 20 dotazů za 8 sekund na jeden klíč; dva si necháváme v rezervě.
$rateLimit = 18
$rateWindow = 8.0

# Sekce se načítají souběžně v několika vláknech, takže si časy odeslaných dotazů hlídají ve společné frontě
# ($context.Limiter, System.Collections.Queue). Když je okno plné, počká se, až nejstarší dotaz vypadne.
function Wait-RateLimit($limiter) {
    # Ne "-not $limiter": prázdná fronta by se tvářila jako žádná.
    if ($null -eq $limiter) { return }
    while ($true) {
        [Threading.Monitor]::Enter($limiter.SyncRoot)
        try {
            $now = [DateTime]::UtcNow
            while ($limiter.Count -gt 0 -and ($now - $limiter.Peek()).TotalSeconds -ge $rateWindow) { $null = $limiter.Dequeue() }
            if ($limiter.Count -lt $rateLimit) {
                $limiter.Enqueue($now)
                return
            }
            $wait = $rateWindow - ($now - $limiter.Peek()).TotalSeconds
        } finally { [Threading.Monitor]::Exit($limiter.SyncRoot) }
        Start-Sleep -Milliseconds ([Math]::Max(50, [int]($wait * 1000)))
    }
}

function Invoke-Api($context, [string]$path, $query = @{}) {
    if ($context.Demo) { return Read-Demo $context.Demo $path }
    Wait-RateLimit $context.Limiter
    Invoke-Http ('https://api.golemio.cz' + $path + (Format-Query $query)) $context.Token 'Golemio'
}

# Číselníky a popisy spojů se za běhu nemění; stačí je stáhnout jednou. Okno dává všem úlohám společnou
# paměť ($context.Cache, synchronizovaná tabulka), jinak by si každé vlákno stahovalo totéž znovu.
function Get-Cached($context, [string]$path, $query = @{}) {
    $cache = $context.Cache
    if ($null -eq $cache) {
        if (-not $global:GolemWatchCache) { $global:GolemWatchCache = @{} }
        $cache = $global:GolemWatchCache
    }
    $key = "$($context.Demo)|$path"
    if (-not $cache.ContainsKey($key)) {
        $value = Invoke-Api $context $path $query
        # Popisy spojů přibývají celý den; občasné vymazání udrží paměť malou.
        if ($cache.Count -ge 500) { $cache.Clear() }
        $cache[$key] = $value
    }
    $cache[$key]
}

function Format-Utc([DateTime]$time) { $time.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant) }

# Světová strana, kam míří azimut ve stupních: 0 = S, 90 = V.
function Format-Compass($bearing) {
    if ($null -eq $bearing -or "$bearing" -eq '') { return '' }
    ('S', 'SV', 'V', 'JV', 'J', 'JZ', 'Z', 'SZ')[[int][Math]::Round((([double]$bearing % 360) + 360) % 360 / 45) % 8]
}

# ---- Poloha a čas ----

function Get-Distance([double]$latitude1, [double]$longitude1, [double]$latitude2, [double]$longitude2) {
    $rad = [Math]::PI / 180
    $a = [Math]::Pow([Math]::Sin(($latitude2 - $latitude1) * $rad / 2), 2) +
        [Math]::Cos($latitude1 * $rad) * [Math]::Cos($latitude2 * $rad) * [Math]::Pow([Math]::Sin(($longitude2 - $longitude1) * $rad / 2), 2)
    2 * 6371000 * [Math]::Asin([Math]::Sqrt($a))
}

function Format-Distance([double]$meters) {
    if ($meters -lt 995) { '{0} m' -f ([int]([Math]::Round($meters / 10) * 10)) }
    else { [string]::Format($cs, '{0:0.#} km', $meters / 1000) }
}

# "šířka,délka,šířka,délka" levého horního a pravého dolního rohu čtverce, jehož strany jsou $radius metrů od středu.
function Get-BoundingBox([double]$latitude, [double]$longitude, [double]$radius) {
    $dLat = $radius / 6371000 * 180 / [Math]::PI
    $dLng = $dLat / [Math]::Cos($latitude * [Math]::PI / 180)
    (Format-LatLng ($latitude + $dLat) ($longitude - $dLng)) + ',' + (Format-LatLng ($latitude - $dLat) ($longitude + $dLng))
}

# Pozice v GeoJSON je [délka, šířka]. U polygonu se vezme první vrchol, na umístění to stačí.
function Read-Position($coordinates) {
    while ($coordinates -is [array] -and $coordinates.Count -gt 0 -and $coordinates[0] -is [array]) { $coordinates = $coordinates[0] }
    if ($coordinates -isnot [array] -or $coordinates.Count -lt 2) { return }
    $position = @{ Latitude = [double]$coordinates[1]; Longitude = [double]$coordinates[0] }
    if ([Math]::Abs($position.Latitude) -le 90 -and [Math]::Abs($position.Longitude) -le 180) { $position }
}

# Prvky GeoJSON kolekce, které mají vlastnosti i polohu, se vzdáleností od zadaného bodu.
function Get-Features($collection, [double]$latitude, [double]$longitude) {
    foreach ($feature in @($collection.features)) {
        if (-not $feature -or -not $feature.properties) { continue }
        $position = Read-Position $feature.geometry.coordinates
        if (-not $position) { continue }
        @{
            Properties = $feature.properties
            Position = $position
            Distance = Get-Distance $latitude $longitude $position.Latitude $position.Longitude
        }
    }
}

function Get-PragueNow { [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $pragueZone) }

function ConvertTo-PragueTime($text) {
    $value = [DateTimeOffset]::MinValue
    if ($text -and [DateTimeOffset]::TryParse([string]$text, $invariant, 'AssumeUniversal', [ref]$value)) {
        [TimeZoneInfo]::ConvertTime($value, $pragueZone)
    }
}

# Datum bez času: "2026-10-07" nebo celý časový údaj.
function ConvertTo-Day($text) {
    $value = [DateTime]::MinValue
    if ($text -and [DateTime]::TryParseExact([string]$text, 'yyyy-MM-dd', $invariant, 'None', [ref]$value)) { return $value }
    $time = ConvertTo-PragueTime $text
    if ($time) { $time.Date }
}

# "dnes", "zítra", "st 7. 10."
function Format-Day([DateTime]$day) {
    switch (($day.Date - (Get-PragueNow).Date).Days) {
        0 { 'dnes' }
        1 { 'zítra' }
        default { $day.ToString('ddd d. M.', $cs) }
    }
}

function Format-Clock($time) { $time.ToString('H\:mm', $invariant) }

function Format-Number($value, [string]$format = '0.#') { [string]::Format($cs, "{0:$format}", [double]$value) }

function ConvertTo-Int($value) { if ($null -ne $value -and "$value" -ne '') { [int][Math]::Round([double]$value) } }

# ---- Svoz odpadu ----

# Barvy kontejnerů podle druhu odpadu (id z API).
$wasteColors = @{
    1 = '#3FA34D'; 2 = '#E5484D'; 3 = '#A3A9B8'; 4 = '#F2994A'; 5 = '#3B82F6'
    6 = '#F5C542'; 7 = '#E8EAF0'; 8 = '#B48EF2'; 9 = '#2DD4BF'
}

function Get-Waste($context, [double]$latitude, [double]$longitude) {
    $range = Get-Option $context 'WasteRange'
    $stations = Invoke-Api $context '/v2/sortedwastestations' ([ordered]@{
        latlng = Format-LatLng $latitude $longitude; range = $range; limit = 3
    })

    $now = Get-PragueNow
    $nests = @(Get-Features $stations $latitude $longitude | Where-Object { $_.Distance -le $range } | Sort-Object { $_.Distance } | Select-Object -First 3 | ForEach-Object {
        $station = $_.Properties
        # Stanoviště mívá víc kontejnerů téhož druhu; pro přehled stačí jeden řádek na druh.
        $kinds = @(@($station.containers) | Where-Object { $_ } | Group-Object { [string]$_.trash_type.id } | ForEach-Object {
            $first = $_.Group[0]
            $next = @($_.Group | ForEach-Object { ConvertTo-Day $_.cleaning_frequency.next_pick } | Where-Object { $_ -and $_ -ge $now.Date } | Sort-Object)[0]
            $fill = @($_.Group | ForEach-Object { ConvertTo-Int $_.last_measurement.percent_calculated } | Where-Object { $null -ne $_ } | Sort-Object -Descending)[0]
            $color = $wasteColors[[int](ConvertTo-Int $first.trash_type.id)]
            [pscustomobject]@{
                Type = if ($first.trash_type.description) { [string]$first.trash_type.description } else { 'Odpad' }
                Color = if ($color) { $color } else { '#8C93A8' }
                PickDays = [string]$first.cleaning_frequency.pick_days
                Day = if ($next) { $next } else { [DateTime]::MaxValue }
                Next = if ($next) { Format-Day $next } else { '' }
                Fill = if ($null -ne $fill) { "$fill %" } else { '' }
            }
        # Nahoře to, co se sveze nejdřív; druhy bez termínu až na konci.
        } | Sort-Object Day, Type)

        [pscustomobject]@{
            Name = if ($station.name) { [string]$station.name } else { 'Stanoviště' }
            Distance = Format-Distance $_.Distance
            Access = [string]$station.accessibility.description
            Kinds = $kinds
        }
    })

    # Velkoobjemové kontejnery jsou navíc; když selžou, tříděný odpad se ukáže i tak.
    $bulky = @()
    $bulkyError = ''
    $bulkyAllowed = $true
    try {
        # Jako jediný bere tenhle endpoint vzdálenost v kilometrech.
        $containers = Invoke-Api $context '/v1/bulky-waste/stations' ([ordered]@{ latlng = Format-LatLng $latitude $longitude; range = 2 })
        $bulky = @(Get-Features $containers $latitude $longitude | Where-Object { $_.Distance -le 1500 } | ForEach-Object {
            $day = ConvertTo-Day $_.Properties.date
            if ($day -and $day -ge $now.Date) {
                $hours = @($_.Properties.timeFrom, $_.Properties.timeTo | Where-Object { $_ } | ForEach-Object { ([string]$_) -replace '^0?(\d+):(\d\d).*$', '$1:$2' }) -join '–'
                [pscustomobject]@{
                    Day = $day
                    Meters = $_.Distance
                    When = ((Format-Day $day), $hours | Where-Object { $_ }) -join ' · '
                    Street = [string]$_.Properties.street
                    Distance = Format-Distance $_.Distance
                }
            }
        } | Sort-Object Day, Meters | Select-Object -First 4)
    } catch {
        # Běžný klíč k téhle sadě přístup mít nemusí. To není porucha, část se prostě neukáže.
        if ($_.Exception.Data['Kind'] -eq 'Forbidden') { $bulkyAllowed = $false } else { $bulkyError = $_.Exception.Message }
    }

    [pscustomobject]@{
        Meta = if ($nests) { "$($nests.Count) nejbližší" } else { '' }
        Stations = $nests
        ShowBulky = $bulkyAllowed
        Bulky = $bulky
        BulkyNote = if ($bulkyError) { $bulkyError } elseif ($bulkyAllowed -and -not $bulky) { 'V okolí teď žádný není v plánu.' } else { '' }
        Empty = if ($nests) { '' } else { "Do $(Format-Distance $range) žádné stanoviště tříděného odpadu není." }
    }
}

# ---- Ovzduší ----

function Format-Formula([string]$code) {
    # NO2 -> NO₂, PM2_5 -> PM2,5
    if ($code -match '^PM') { return $code -replace '_', ',' }
    $code -replace '2', [string][char]0x2082 -replace '3', [string][char]0x2083
}

# Index ovzduší je hodinový; starší měření už o vzduchu venku nic neříká.
$airFreshHours = 6

function Get-Air($context, [double]$latitude, [double]$longitude) {
    $stations = Invoke-Api $context '/v2/airqualitystations' ([ordered]@{ latlng = Format-LatLng $latitude $longitude; limit = 10 })
    $nearest = @(Get-Features $stations $latitude $longitude | Sort-Object { $_.Distance })
    if (-not $nearest) { return [pscustomobject]@{ Meta = ''; Empty = 'Golemio nevrátilo žádnou měřicí stanici.' } }

    # Seznam stanic nese poslední stav, který k němu Golemio dostalo, a ten bývá i měsíce starý. Čerstvá měření
    # jsou v historii: jeden dotaz na všechny stanice, ať se nemusí zkoušet jedna po druhé.
    $newest = @{}
    try {
        $history = Invoke-Api $context '/v2/airqualitystations/history' ([ordered]@{ from = Format-Utc ([DateTime]::UtcNow.AddHours(-$airFreshHours)) })
        foreach ($row in @($history)) {
            $time = if ($row) { ConvertTo-PragueTime $row.updated_at }
            if ($time -and $row.id -and (-not $newest[[string]$row.id] -or $time -gt $newest[[string]$row.id].Time)) {
                $newest[[string]$row.id] = @{ Time = $time; Measurement = $row.measurement }
            }
        }
    } catch { }

    $now = Get-PragueNow
    $readings = @(foreach ($candidate in $nearest) {
        $reading = $newest[[string]$candidate.Properties.id]
        if (-not $reading) { $reading = @{ Time = ConvertTo-PragueTime $candidate.Properties.updated_at; Measurement = $candidate.Properties.measurement } }
        # Stanice, která zrovna nic neměří, se přeskočí; vezme se nejbližší, která data má.
        if (@($reading.Measurement.components | Where-Object { $null -ne $_.averaged_time.value }).Count) {
            @{ Station = $candidate; Time = $reading.Time; Measurement = $reading.Measurement }
        }
    })
    if (-not $readings) { return [pscustomobject]@{ Meta = ''; Empty = 'Žádná stanice v okolí teď neměří.' } }

    # Staré měření se jako aktuální ukázat nesmí. Chybí-li čas úplně, nedá se stáří posoudit a měření se ukáže.
    $reading = @($readings | Where-Object { -not $_.Time -or ($now - $_.Time).TotalHours -le $airFreshHours })[0]
    if (-not $reading) {
        $last = @($readings | ForEach-Object { $_.Time } | Sort-Object -Descending)[0]
        return [pscustomobject]@{
            Meta = ''
            Empty = "Golemio má poslední měření ovzduší z $($last.ToString('d. M.', $cs)) v $(Format-Clock $last). Novější teď neposkytuje."
        }
    }
    $station = $reading.Station
    $measurement = $reading.Measurement

    # Číselníky jsou jen na popisky a barvy; bez nich se ukážou holé kódy.
    $indexTypes = @(); $componentTypes = @()
    try {
        $indexTypes = @(Get-Cached $context '/v2/airqualitystations/indextypes')
        $componentTypes = @(Get-Cached $context '/v2/airqualitystations/componenttypes')
    } catch { }

    # Specifikace uvádí index jako číslo, číselník má ale kódy typu "1A"; bereme obojí.
    $code = if ($null -ne $measurement.AQ_hourly_index) { [string]$measurement.AQ_hourly_index } else { '' }
    $index = @($indexTypes | Where-Object { $code -and ([string]$_.index_code -eq $code -or [string]$_.id -eq $code) })[0]
    $description = [string]$index.description_cs

    $components = @(@($measurement.components) | Where-Object { $_ -and $_.type -and $null -ne $_.averaged_time.value } | ForEach-Object {
        $component = $_
        $type = @($componentTypes | Where-Object { $_.component_code -eq $component.type })[0]
        $hours = ConvertTo-Int $_.averaged_time.averaged_hours
        [pscustomobject]@{
            Code = [string]$_.type
            Hours = [int]$hours
            Name = Format-Formula ([string]$_.type)
            Description = [string]$type.description_cs
            Value = ((Format-Number $_.averaged_time.value), [string]$type.unit | Where-Object { $_ }) -join ' '
            Period = if ($hours) { "průměr za $hours h" } else { '' }
            # Totéž na jeden řádek karty.
            Detail = ([string]$type.description_cs, $(if ($hours) { "$hours h" }) | Where-Object { $_ }) -join ' · '
        }
    } | Sort-Object Code, Hours)

    $updated = $reading.Time
    [pscustomobject]@{
        Meta = "$($station.Properties.name) · $(Format-Distance $station.Distance)"
        Index = if ($description) { $description.Substring(0, 1).ToUpper($cs) + $description.Substring(1) } elseif ($code) { "Index $code" } else { 'Index není k dispozici' }
        IndexColor = if ($index.color) { '#' + $index.color } else { '#222838' }
        IndexTextColor = if ($index.color_text) { '#' + $index.color_text } else { '#ECEEF4' }
        Updated = if ($updated) { 'měřeno ' + (Format-Day $updated.Date) + ' v ' + (Format-Clock $updated) } else { '' }
        Components = $components
        Empty = ''
    }
}

# ---- Mikroklima ----

# Veličiny v pořadí, v jakém je karta ukazuje. Kód z API má za názvem výšku čidla v cm (air_temp200).
$microclimateMeasures = [ordered]@{
    air_temp = 'Teplota'; air_hum = 'Vlhkost'; pressure = 'Tlak'; wind_speed = 'Vítr'
    wind_impact = 'Nárazy větru'; wind_dir = 'Směr větru'; precip = 'Srážky'; sun_irr = 'Osvit'
}
# Senzory hlásí po deseti minutách; dvě hodiny zpět stačí a odpověď za všechny senzory zůstane malá.
$microclimateHours = 2

function Format-Measure([string]$base, $value, [string]$unit) {
    if ($base -eq 'wind_dir') { return Format-Compass $value }
    # Tlak chodí v pascalech, zvyk je v hektopascalech.
    if ($unit -eq 'Pa') { return (Format-Number ([double]$value / 100) '0') + ' hPa' }
    ((Format-Number $value), $unit | Where-Object { $_ }) -join ' '
}

function Get-Microclimate($context, [double]$latitude, [double]$longitude) {
    # Specifikace tu popisuje jeden objekt, i když jde o seznam; @() srovná obojí.
    $points = @(@(Get-Cached $context '/v2/microclimate/points') | Where-Object { $_ -and $null -ne $_.lat -and $null -ne $_.lng -and $null -ne $_.point_id })
    if (-not $points) { return [pscustomobject]@{ Meta = ''; Empty = 'Golemio nevrátilo žádný senzor mikroklimatu.' } }

    # Jeden dotaz na všechny senzory: nejbližší často mlčí a zkoušet je po jednom by stálo dotaz za každý.
    $measured = @{}
    foreach ($row in @(Invoke-Api $context '/v2/microclimate/measurements' ([ordered]@{ from = Format-Utc ([DateTime]::UtcNow.AddHours(-$microclimateHours)) }))) {
        if (-not $row -or -not $row.measure -or $null -eq $row.value) { continue }
        $key = [string]$row.point_id
        if (-not $measured.ContainsKey($key)) { $measured[$key] = New-Object System.Collections.ArrayList }
        $null = $measured[$key].Add($row)
    }
    $point = @($points | Where-Object { $measured.ContainsKey([string]$_.point_id) } |
        Sort-Object { Get-Distance $latitude $longitude ([double]$_.lat) ([double]$_.lng) })[0]
    if (-not $point) { return [pscustomobject]@{ Meta = ''; Empty = 'Golemio teď nemá čerstvá data z žádného senzoru mikroklimatu.' } }

    $latest = $null
    $order = @($microclimateMeasures.Keys)
    # Stejná veličina z více výšek se ukáže jednou, z té vyšší (dva metry jsou běžná výška měření).
    $values = @($measured[[string]$point.point_id] | Group-Object { ([string]$_.measure) -replace '\d+$' } | ForEach-Object {
        $base = $_.Name
        $height = @($_.Group | ForEach-Object { if ([string]$_.measure -match '(\d+)$') { [int]$Matches[1] } else { 0 } } | Sort-Object -Descending)[0]
        $last = @($_.Group | Where-Object { [string]$_.measure -eq $(if ($height) { "$base$height" } else { $base }) } |
            Sort-Object { ConvertTo-PragueTime $_.measured_at } -Descending)[0]
        $time = ConvertTo-PragueTime $last.measured_at
        if ($time -and (-not $latest -or $time -gt $latest)) { $latest = $time }
        $measure = @($point.measures | Where-Object { $_.measure -eq $last.measure })[0]
        [pscustomobject]@{
            # Vlastní krátké jméno, jinak české jméno z číselníku senzoru, jinak aspoň kód.
            Name = @($microclimateMeasures[$base], $measure.measure_cz, [string]$last.measure | Where-Object { $_ })[0]
            Value = Format-Measure $base $last.value ([string]$last.unit)
            Order = if ($base -in $order) { [array]::IndexOf($order, $base) } else { $order.Count }
        }
    } | Sort-Object Order, Name)

    # Bod se podle specifikace jmenuje point_named, naživo point_name.
    $name = @($point.point_named, $point.point_name, $point.location | Where-Object { $_ })[0]
    [pscustomobject]@{
        Meta = "$name · $(Format-Distance (Get-Distance $latitude $longitude ([double]$point.lat) ([double]$point.lng)))"
        Values = $values
        Updated = if ($latest) { 'měřeno v ' + (Format-Clock $latest) } else { '' }
        Empty = ''
    }
}

# ---- Parkování ----

$parkingKinds = @{
    park_and_ride = 'P+R'; kiss_and_ride = 'K+R'; commercial = 'Placené'; customer_only = 'Pro zákazníky'
    park_sharing = 'Sdílené'; zone = 'Zóna'
    underground = 'Podzemní'; multi_storey = 'Parkovací dům'; surface = 'Parkoviště'; on_street = 'Na ulici'; rooftop = 'Na střeše'
}

function Get-Parking($context, [double]$latitude, [double]$longitude) {
    $range = Get-Option $context 'ParkingRange'
    $parking = Invoke-Api $context '/v3/parking' ([ordered]@{
        boundingBox = Get-BoundingBox $latitude $longitude $range
        # Všechno kromě "zone": pouličních zón jsou v každém bloku desítky. "none" = parkování bez režimu.
        'parkingPolicy[]' = 'commercial', 'customer_only', 'kiss_and_ride', 'park_and_ride', 'park_sharing', 'none'
    })

    $places = @(foreach ($feature in @($parking.features)) {
        if (-not $feature -or -not $feature.properties -or -not $feature.properties.id) { continue }
        # Geometrie bývá obrys parkoviště, proto má přednost těžiště.
        $position = Read-Position $feature.properties.centroid.coordinates
        if (-not $position) { $position = Read-Position $feature.geometry.coordinates }
        if (-not $position) { continue }
        @{ Properties = $feature.properties; Distance = Get-Distance $latitude $longitude $position.Latitude $position.Longitude }
    # API vrací čtverec kolem místa; co je v jeho rozích dál než okruh, se zahodí.
    }) | Where-Object { $_.Distance -le $range } | Sort-Object { $_.Distance } | Select-Object -First 6
    if (-not $places) { return [pscustomobject]@{ Meta = ''; Empty = "Do $(Format-Distance $range) žádné parkoviště není." } }

    # Obsazenost je v samostatném endpointu a má ji jen část parkovišť.
    $occupancy = @{}
    $ids = @($places | Where-Object { $_.Properties.has_occupancy_info } | ForEach-Object { [string]$_.Properties.id })
    if ($ids) {
        try {
            foreach ($row in @(Invoke-Api $context '/v3/parking-measurements' ([ordered]@{ 'parkingId[]' = $ids }))) {
                if ($row.parking_id) { $occupancy[[string]$row.parking_id] = $row }
            }
        } catch { }
    }

    # Parkovací automat je jen doplněk; když dotaz selže nebo žádný poblíž není, řádek se neukáže.
    $machine = ''
    try {
        $machines = Invoke-Api $context '/v3/parking-machines' ([ordered]@{ boundingBox = Get-BoundingBox $latitude $longitude $range; limit = 200 })
        $closest = @(Get-Features $machines $latitude $longitude | Where-Object { $_.Distance -le $range } | Sort-Object { $_.Distance })[0]
        if ($closest) { $machine = 'Nejbližší parkovací automat ' + (Format-Distance $closest.Distance) }
    } catch { }

    [pscustomobject]@{
        Meta = 'do ' + (Format-Distance $range)
        Machine = $machine
        Items = @($places | ForEach-Object {
            $p = $_.Properties
            $measured = $occupancy[[string]$p.id]
            $capacity = ConvertTo-Int $(if ($measured -and $null -ne $measured.total_spot_number) { $measured.total_spot_number } else { $p.capacity })
            $free = if ($measured) { ConvertTo-Int $measured.free_spot_number }
            $kind = $parkingKinds[[string]$p.parking_policy]
            if (-not $kind) { $kind = $parkingKinds[[string]$p.parking_type] }
            [pscustomobject]@{
                Name = @($p.name, $p.address.address_formatted, 'Parkoviště' | Where-Object { $_ })[0]
                Kind = [string]$kind
                Distance = Format-Distance $_.Distance
                # Vzdálenost první: když se řádek do karty nevejde celý, ořízne se konec.
                Detail = ((Format-Distance $_.Distance), [string]$kind | Where-Object { $_ }) -join ' · '
                # Bez měření obsazenosti se místo volných míst ukáže aspoň kapacita (šedě, viz FreeColor).
                Free = if ($null -ne $free) { "$free" } elseif ($capacity) { "$capacity" } else { '' }
                Capacity = if ($null -ne $free -and $capacity) { "volných z $capacity" } elseif ($null -ne $free) { 'volných' } elseif ($capacity) { 'míst' } else { '' }
                FreeColor = if ($null -eq $free) { '#8C93A8' } elseif ($free -eq 0) { '#FF8A80' } else { '#7BD88F' }
            }
        })
        Empty = ''
    }
}

# ---- MHD ----

# Typy linek podle GTFS a barvy, jak je používá PID.
$routeColors = @{ 0 = '#7A0603'; 1 = '#5B6170'; 2 = '#251E62'; 3 = '#007DA8'; 4 = '#00B3CB'; 7 = '#7A0603'; 11 = '#80166F' }
$metroColors = @{ A = '#00A562'; B = '#F8B322'; C = '#CF003D'; D = '#008BBE' }

# Najde nástupiště v okolí. Endpoint neumí filtr podle polohy, takže se přečte celý seznam po stránkách.
function Find-Stops($context, [double]$latitude, [double]$longitude) {
    $pageSize = 10000
    $range = Get-Option $context 'StopsRange'
    $near = New-Object System.Collections.ArrayList
    for ($offset = 0; ; $offset += $pageSize) {
        $page = Invoke-Api $context '/v2/gtfs/stops' ([ordered]@{ limit = $pageSize; offset = $offset })
        foreach ($stop in (Get-Features $page $latitude $longitude)) {
            $p = $stop.Properties
            # location_type 0 je nástupiště; stanice, vstupy a další uzly odjezdy nemají.
            if ($stop.Distance -le $range -and $p.stop_id -and (-not $p.location_type -or [int]$p.location_type -eq 0)) {
                $null = $near.Add([pscustomobject]@{
                    Id = [string]$p.stop_id
                    Name = if ($p.stop_name) { [string]$p.stop_name } else { [string]$p.stop_id }
                    Platform = [string]$p.platform_code
                    Meters = $stop.Distance
                })
            }
        }
        if (@($page.features).Count -lt $pageSize) { break }
    }
    # Celý seznam zastávek zabere desítky megabajtů; bez úklidu by si je proces držel ještě dlouho.
    $page = $null
    [GC]::Collect()
    @($near | Sort-Object Meters | Select-Object -First 10)
}

function Get-RouteColor($type, [string]$route) {
    if ($type -eq 1 -and $metroColors[$route]) { return $metroColors[$route] }
    if ($null -ne $type -and $routeColors[[int]$type]) { return $routeColors[[int]$type] }
    '#5B6170'
}

function Get-Transit($context, [double]$latitude, [double]$longitude, $stops) {
    if ($null -eq $stops) { $stops = @(Find-Stops $context $latitude $longitude) }
    $stops = @($stops)
    if (-not $stops) {
        $range = Format-Distance (Get-Option $context 'StopsRange')
        return [pscustomobject]@{ Meta = ''; Stops = $stops; Departures = @(); Infotexts = @(); Empty = "Do $range žádná zastávka PID není." }
    }

    $count = Get-Option $context 'Departures'
    $board = Invoke-Api $context '/v2/pid/departureboards' ([ordered]@{
        'ids[]' = @($stops | ForEach-Object Id); minutesAfter = 90; limit = $count
    })

    $names = @{}
    foreach ($stop in $stops) { $names[$stop.Id] = $stop }
    $now = Get-PragueNow

    $departures = @(@($board.departures) | Where-Object { $_ } | Select-Object -First $count | ForEach-Object {
        $scheduled = ConvertTo-PragueTime $_.departure_timestamp.scheduled
        $predicted = ConvertTo-PragueTime $_.departure_timestamp.predicted
        $time = if ($predicted) { $predicted } else { $scheduled }
        if (-not $time) { return }

        $minutes = [int][Math]::Floor(($time - $now).TotalMinutes)
        $delay = if ($_.delay.is_available -and $null -ne $_.delay.seconds) { [int][Math]::Round([double]$_.delay.seconds / 60) } else { 0 }
        $stop = $names[[string]$_.stop.id]
        $platform = @($_.stop.platform_code, $stop.Platform | Where-Object { $_ })[0]
        $route = [string]$_.route.short_name
        $type = ConvertTo-Int $_.route.type
        $color = Get-RouteColor $type $route
        $canceled = [bool]$_.trip.is_canceled

        [pscustomobject]@{
            Route = $route
            Color = $color
            # Žlutá linka B potřebuje tmavé písmo, na ostatních barvách je čitelné bílé.
            RouteTextColor = if ($color -eq $metroColors.B) { '#1F1405' } else { '#FFFFFF' }
            Headsign = [string]$_.trip.headsign
            Stop = ((@($stop.Name, [string]$_.stop.id | Where-Object { $_ })[0]), $platform | Where-Object { $_ }) -join ' · '
            In = if ($canceled) { 'zrušeno' } elseif ($_.trip.is_at_stop -or $minutes -le 0) { 'teď' } else { "za $minutes min" }
            InColor = if ($canceled) { '#FF8A80' } else { '#ECEEF4' }
            Time = Format-Clock $time
            Delay = if ($delay -ge 1 -and -not $canceled) { "+$delay min" } else { '' }
            Opacity = if ($canceled) { 0.55 } else { 1.0 }
        }
    })

    $stopNames = @($stops | ForEach-Object Name | Select-Object -Unique)
    [pscustomobject]@{
        Meta = (@($stopNames | Select-Object -First 3) -join ', ') + $(if ($stopNames.Count -gt 3) { ' a další' } else { '' })
        Stops = $stops
        Departures = $departures
        Infotexts = @(@($board.infotexts) | Where-Object { $_ -and $_.text } | ForEach-Object { [pscustomobject]@{ Text = [string]$_.text } })
        Empty = if ($departures) { '' } else { 'V příští hodině a půl odsud nic nejede.' }
    }
}

# ---- Vozidla MHD v okolí ----

# Druh dopravy tu chodí slovem; barvy jsou stejné jako u odjezdů (číselné typy GTFS).
$routeTypes = @{ tram = 0; metro = 1; train = 2; bus = 3; ferry = 4; funicular = 7; trolleybus = 11 }
$vehicleRange = 1000

function Get-Vehicles($context, [double]$latitude, [double]$longitude) {
    $positions = Invoke-Api $context '/v2/public/vehiclepositions' ([ordered]@{ boundingBox = Get-BoundingBox $latitude $longitude $vehicleRange })
    $near = @(Get-Features $positions $latitude $longitude | Where-Object { $_.Distance -le $vehicleRange } | Sort-Object { $_.Distance })
    if (-not $near) { return [pscustomobject]@{ Meta = ''; Empty = "Do $(Format-Distance $vehicleRange) teď žádný spoj MHD nejede." } }

    [pscustomobject]@{
        Meta = "$($near.Count) do $(Format-Distance $vehicleRange)"
        Items = @($near | Select-Object -First 8 | ForEach-Object {
            $vehicle = $_
            $p = $vehicle.Properties
            $route = [string]$p.gtfs_route_short_name
            # Kam spoj jede, v polohách není. Dotáže se jednou na každý spoj a pak už se bere z paměti.
            $headsign = ''
            if ($p.gtfs_trip_id) {
                try { $headsign = [string](Get-Cached $context "/v2/public/gtfs/trips/$($p.gtfs_trip_id)" ([ordered]@{ 'scopes[]' = 'info' })).trip_headsign } catch { }
            }
            $delay = if ($null -ne $p.delay) { [int][Math]::Round([double]$p.delay / 60) } else { 0 }
            $color = Get-RouteColor ($routeTypes[[string]$p.route_type]) $route
            [pscustomobject]@{
                Route = $route
                Color = $color
                RouteTextColor = if ($color -eq $metroColors.B) { '#1F1405' } else { '#FFFFFF' }
                Headsign = $headsign
                State = if ($p.state_position -eq 'at_stop') { 'v zastávce' } else { (('směr ' + (Format-Compass $p.bearing)) -replace '^směr $') }
                Delay = if ($delay -ge 1) { "+$delay min" } else { '' }
                Distance = Format-Distance $vehicle.Distance
            }
        })
        Empty = ''
    }
}

# ---- Mimořádnosti PID ----

function Get-Alerts($context, [double]$latitude, [double]$longitude) {
    $order = @{ high = 0; normal = 1; low = 2 }
    # Stejný text chodí zvlášť pro každou dotčenou zastávku; v kartě je jednou a zastávky se sečtou.
    $all = @(@(Invoke-Api $context '/v3/pid/infotexts') | Where-Object { $_ -and $_.text } | Group-Object { [string]$_.text } | ForEach-Object {
        $rank = @($_.Group | ForEach-Object { if ($order.ContainsKey([string]$_.priority)) { $order[[string]$_.priority] } else { 1 } } | Sort-Object)[0]
        @{
            Text = $_.Name
            Rank = $rank
            Stops = @($_.Group | ForEach-Object { $_.related_stops } | ForEach-Object { [string]$_.name } | Where-Object { $_ } | Select-Object -Unique)
            Until = @($_.Group | ForEach-Object { ConvertTo-PragueTime $_.valid_to } | Where-Object { $_ } | Sort-Object -Descending)[0]
        }
    } | Sort-Object { $_.Rank }, { $_.Until })
    if (-not $all) { return [pscustomobject]@{ Meta = ''; Empty = 'PID teď žádnou mimořádnost nehlásí.' } }

    $shown = 4
    $today = (Get-PragueNow).Date
    [pscustomobject]@{
        Meta = "$($all.Count) v celé síti"
        Items = @($all | Select-Object -First $shown | ForEach-Object {
            [pscustomobject]@{
                Text = $_.Text
                Stops = (@($_.Stops | Select-Object -First 3) -join ', ') + $(if ($_.Stops.Count -gt 3) { ' a další' } else { '' })
                Until = if (-not $_.Until) { '' } elseif ($_.Until.Date -eq $today) { 'dnes končí' } else { 'do ' + (Format-Day $_.Until.Date) }
                Color = if ($_.Rank -eq 0) { '#FF8A80' } else { '#E9A45B' }
            }
        })
        More = if ($all.Count -gt $shown) { "a $($all.Count - $shown) další" } else { '' }
        Empty = ''
    }
}

# ---- Sdílená auta ----

$carRange = 1500

function Get-Cars($context, [double]$latitude, [double]$longitude) {
    $cars = Invoke-Api $context '/v2/sharedcars' ([ordered]@{ latlng = Format-LatLng $latitude $longitude; range = $carRange; limit = 50 })
    $near = @(Get-Features $cars $latitude $longitude | Where-Object { $_.Distance -le $carRange } | Sort-Object { $_.Distance })
    if (-not $near) { return [pscustomobject]@{ Meta = ''; Empty = "Do $(Format-Distance $carRange) teď žádné sdílené auto nestojí." } }

    [pscustomobject]@{
        Meta = "$($near.Count) do $(Format-Distance $carRange)"
        Items = @($near | Select-Object -First 5 | ForEach-Object {
            $p = $_.Properties
            [pscustomobject]@{
                # Značka bývá v názvu dvakrát ("Toyota Toyota Aygo X").
                Name = ([string]$p.name) -replace '^(\S+) \1 ', '$1 '
                Detail = ([string]$p.company.name, [string]$p.fuel.description, [string]$p.availability.description | Where-Object { $_ }) -join ' · '
                Distance = Format-Distance $_.Distance
            }
        })
        Empty = ''
    }
}

# ---- Cyklosčítače ----

function Get-Cycling($context, [double]$latitude, [double]$longitude) {
    $counters = Invoke-Api $context '/v2/bicyclecounters' ([ordered]@{ latlng = Format-LatLng $latitude $longitude; limit = 3 })
    $near = @(Get-Features $counters $latitude $longitude | Sort-Object { $_.Distance } | Select-Object -First 3)
    if (-not $near) { return [pscustomobject]@{ Meta = ''; Empty = 'Golemio nevrátilo žádný cyklosčítač.' } }

    # Součty od půlnoci za všechny směry nejbližších sčítačů jedním dotazem (je pomalý, i několik sekund).
    $now = Get-PragueNow
    $midnight = [DateTimeOffset]::new($now.Date, $now.Offset).UtcDateTime
    $ids = @($near | ForEach-Object { $_.Properties.directions } | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    $sums = @{}
    foreach ($row in @(Invoke-Api $context '/v2/bicyclecounters/detections' ([ordered]@{ 'id[]' = $ids; from = Format-Utc $midnight; aggregate = $true }))) {
        if ($row -and $row.id) { $sums[[string]$row.id] = $row }
    }

    $counted = @($near | ForEach-Object {
        $directions = @($_.Properties.directions | Where-Object { $_ -and $_.id } | ForEach-Object {
            $sum = $sums[[string]$_.id]
            @{ Name = [string]$_.name; Bikes = [int](ConvertTo-Int $sum.value); Walkers = ConvertTo-Int $sum.value_pedestrians }
        })
        @{ Counter = $_; Directions = $directions; Total = ($directions | ForEach-Object { $_.Bikes } | Measure-Object -Sum).Sum }
    })
    # Sčítač, který nefunguje, hlásí celý den nulu; vezme se nejbližší, který dnes něco napočítal.
    $picked = @($counted | Where-Object { $_.Total -gt 0 })[0]
    if (-not $picked) { return [pscustomobject]@{ Meta = ''; Empty = 'Nejbližší cyklosčítače dnes zatím žádný průjezd nezapsaly.' } }

    $p = $picked.Counter.Properties
    [pscustomobject]@{
        Meta = "$($p.name) · $(Format-Distance $picked.Counter.Distance)"
        Total = Format-Number $picked.Total '#,0'
        Caption = 'kol od půlnoci' + $(if ($p.route) { " · trasa $($p.route)" } else { '' })
        Items = @($picked.Directions | ForEach-Object {
            [pscustomobject]@{
                Name = 'směr ' + $_.Name
                Value = (Format-Number $_.Bikes '#,0') + $(if ($_.Walkers) { " · pěších $(Format-Number $_.Walkers '#,0')" } else { '' })
            }
        })
        Empty = ''
    }
}

# ---- Městská část ----

# Leží bod uvnitř obrysu? Obrys je seznam vrcholů [délka, šířka]; počítá se, kolikrát ho protne polopřímka z bodu.
function Test-InRing($ring, [double]$latitude, [double]$longitude) {
    $inside = $false
    $points = @($ring)
    for ($i = 0; $i -lt $points.Count; $i++) {
        $a = $points[$i]; $b = $points[($i + 1) % $points.Count]
        $x1 = [double]$a[0]; $y1 = [double]$a[1]; $x2 = [double]$b[0]; $y2 = [double]$b[1]
        if (($y1 -gt $latitude) -ne ($y2 -gt $latitude) -and $longitude -lt ($x2 - $x1) * ($latitude - $y1) / ($y2 - $y1) + $x1) { $inside = -not $inside }
    }
    $inside
}

# Jméno městské části, ve které místo leží; nic, když je mimo Prahu.
function Get-District($context, [double]$latitude, [double]$longitude) {
    $districts = Invoke-Api $context '/v2/citydistricts' ([ordered]@{ latlng = Format-LatLng $latitude $longitude; limit = 4 })
    foreach ($feature in @($districts.features)) {
        if (-not $feature -or -not $feature.geometry) { continue }
        # Polygon má vnější obrys v coordinates[0], MultiPolygon má takových částí víc.
        $polygons = New-Object System.Collections.ArrayList
        if ($feature.geometry.type -eq 'MultiPolygon') { foreach ($polygon in $feature.geometry.coordinates) { $null = $polygons.Add($polygon) } }
        else { $null = $polygons.Add($feature.geometry.coordinates) }
        foreach ($polygon in $polygons) {
            if (Test-InRing ($polygon[0]) $latitude $longitude) { return [string]$feature.properties.name }
        }
    }
    ''
}

# ---- V okolí ----

# Od každého druhu místa se ukáže to nejbližší. Range je v metrech: sběrných dvorů je málo, lékáren hodně.
# Group a Types se navíc hlídají i tady, protože zdravotnická zařízení jsou v jedné sadě všechna dohromady.
# Zahrad je v celé Praze pár desítek, proto se hledají bez omezení vzdálenosti.
$nearbyKinds = @(
    @{ Label = 'Lékárna'; Path = '/v2/medicalinstitutions'; Group = 'pharmacies'; Range = 3000 }
    @{ Label = 'Nemocnice'; Path = '/v2/medicalinstitutions'; Group = 'health_care'; Types = 'Nemocnice', 'Fakultní nemocnice'; Range = 10000; Limit = 300 }
    @{ Label = 'Knihovna'; Path = '/v2/municipallibraries'; Range = 5000 }
    @{ Label = 'Úřad'; Path = '/v2/municipalauthorities'; Range = 5000 }
    @{ Label = 'Městská policie'; Path = '/v2/municipalpolicestations'; Range = 5000 }
    @{ Label = 'Sběrný dvůr'; Path = '/v2/wastecollectionyards'; Range = 10000 }
    @{ Label = 'Hřiště'; Path = '/v2/playgrounds'; Range = 5000 }
    @{ Label = 'Zahrada'; Path = '/v2/gardens' }
)

# "09:00" -> 540 minut od půlnoci; nic, když to není čas.
function ConvertTo-Minutes($text) {
    if ("$text" -match '^\s*(\d{1,2}):(\d\d)') { [int]$Matches[1] * 60 + [int]$Matches[2] }
}

function Format-Minutes([int]$minutes) { '{0}:{1:00}' -f [Math]::Floor($minutes / 60), ($minutes % 60) }

# Z otevírací doby (dny v týdnu anglicky, časy "HH:mm") udělá "otevřeno do 18:00", "otevírá v 9:00",
# "otevírá zítra v 8:00" nebo "otevírá po v 8:00". Vrací @{ Text; Open }, nebo nic, když doba chybí.
function Get-OpenStatus($hours, $now) {
    $valid = @(@($hours) | Where-Object {
        $from = ConvertTo-PragueTime $_.valid_from
        $through = ConvertTo-PragueTime $_.valid_through
        $_ -and $null -ne (ConvertTo-Minutes $_.opens) -and $null -ne (ConvertTo-Minutes $_.closes) -and
            # Samoobslužný provoz knihoven (vracení knih do boxu) není otevřeno.
            $_.type -ne 'self_service' -and
            (-not $from -or $from -le $now) -and (-not $through -or $through -ge $now)
    })
    if (-not $valid) { return }
    # Mimořádná doba (svátky, prázdniny) má po dobu své platnosti přednost před běžnou.
    $special = @($valid | Where-Object { $_.ContainsKey('is_default') -and -not $_.is_default })
    if ($special) { $valid = $special }

    $minute = $now.Hour * 60 + $now.Minute
    foreach ($offset in 0..7) {
        $day = $now.Date.AddDays($offset)
        $today = @($valid | Where-Object { $_.day_of_week -eq [string]$day.DayOfWeek } | ForEach-Object {
            $opens = ConvertTo-Minutes $_.opens
            $closes = ConvertTo-Minutes $_.closes
            # "08:00–00:00" znamená do půlnoci.
            @{ Opens = $opens; Closes = if ($closes -le $opens) { 24 * 60 } else { $closes } }
        } | Sort-Object { $_.Opens })

        foreach ($interval in $today) {
            if ($offset -eq 0 -and $interval.Opens -le $minute -and $minute -lt $interval.Closes) {
                # Nonstop provoz bývá zapsaný jako 00:00–23:59.
                $allDay = $interval.Opens -eq 0 -and $interval.Closes -ge 24 * 60 - 1
                return @{ Text = if ($allDay) { 'otevřeno nonstop' } else { 'otevřeno do ' + (Format-Minutes $interval.Closes) }; Open = $true }
            }
            if ($offset -gt 0 -or $interval.Opens -gt $minute) {
                $when = switch ($offset) { 0 { '' } 1 { 'zítra ' } default { $day.ToString('ddd', $cs) + ' ' } }
                return @{ Text = "otevírá ${when}v " + (Format-Minutes $interval.Opens); Open = $false }
            }
        }
    }
    @{ Text = 'zavřeno'; Open = $false }
}

function Get-Nearby($context, [double]$latitude, [double]$longitude) {
    $now = Get-PragueNow
    $failure = $null
    $places = @(foreach ($kind in $nearbyKinds) {
        $query = [ordered]@{
            latlng = Format-LatLng $latitude $longitude; range = $kind.Range; group = $kind.Group
            limit = if ($kind.Limit) { $kind.Limit } else { 3 }
        }
        # Každý druh je samostatný dotaz; když jeden selže, ostatní se ukážou i tak.
        try { $found = Invoke-Api $context $kind.Path $query }
        catch {
            if (-not $failure) { $failure = $_ }
            continue
        }
        $nearest = @(Get-Features $found $latitude $longitude | Where-Object {
            (-not $kind.Group -or -not $_.Properties.type.group -or $_.Properties.type.group -eq $kind.Group) -and
            (-not $kind.Types -or [string]$_.Properties.type.description -in $kind.Types)
        } | Sort-Object { $_.Distance })[0]
        if (-not $nearest) { continue }

        $p = $nearest.Properties
        # Úřady mají jen celou adresu "ulice, PSČ město, země"; do karty stačí ulice.
        $street = [string]@($p.address.street_address, ([string]$p.address.address_formatted).Split(',')[0] | Where-Object { $_ })[0]
        $status = Get-OpenStatus $p.opening_hours $now
        # Služebny městské policie jméno nemají, tak je zastoupí adresa.
        $name = [string]@($p.name, $street, $kind.Label | Where-Object { $_ })[0]
        $address = if ($p.name) { $street } else { [string]$p.cadastral_area }
        # Volný text navíc: otevírací doba sběrného dvora a zahrady, vybavení hřiště.
        $hours = [string]@($p.operating_hours, (@($p.properties | Where-Object { $_.id -eq 'doba' })[0].value) | Where-Object { $_ })[0]
        if (-not $hours -and $kind.Path -eq '/v2/playgrounds') {
            $hours = @($p.properties | ForEach-Object { [string]$_.description } | Where-Object { $_ }) -join ', '
        }
        [pscustomobject]@{
            Kind = $kind.Label
            Name = $name
            Address = $address
            Distance = Format-Distance $nearest.Distance
            Status = if ($status) { $status.Text } else { '' }
            StatusColor = if ($status -and $status.Open) { '#7BD88F' } else { '#8C93A8' }
            Hours = $hours
            # V kartě je místo na jeden řádek; zbytek se ukáže po najetí myší.
            Detail = ($name, $address, $hours | Where-Object { $_ }) -join "`n"
        }
    })
    # Když selže úplně všechno, je to chyba klíče nebo sítě a má být vidět.
    if (-not $places -and $failure) { throw $failure }

    [pscustomobject]@{
        Meta = 'nejbližší od každého'
        Items = $places
        Empty = if ($places) { '' } else { 'Golemio v okolí nic nenašlo.' }
    }
}

# ---- Nastavení: ověření klíče a hledání adresy ----

# Projde, když Golemio klíč přijme; jinak vyhodí chybu.
function Test-Token($context) {
    $null = Invoke-Api $context '/v2/airqualitystations/indextypes'
    $true
}

# Adresa odchází na server OpenStreetMap; aplikace na to v okně upozorňuje.
function Find-Address($context, [string]$text) {
    $found = if ($context.Demo) { Read-Demo $context.Demo 'nominatim-search' } else {
        Invoke-Http ('https://nominatim.openstreetmap.org/search' + (Format-Query ([ordered]@{
            q = $text; format = 'jsonv2'; limit = 5; countrycodes = 'cz'; 'accept-language' = 'cs'; addressdetails = 1
        }))) $null 'Nominatim'
    }
    @(@($found) | Where-Object { $_ -and $_.display_name -and $_.lat -and $_.lon } | ForEach-Object {
        [pscustomobject]@{
            Name = [string]$_.display_name
            Label = Format-Place $_
            Latitude = [double]$_.lat
            Longitude = [double]$_.lon
        }
    })
}

# Krátké jméno místa do pole s adresou a do záhlaví přehledu: "Korunní 586/2, Vinohrady".
# Celé jméno z Nominatimu je dlouhé a u domů začíná číslem popisným.
function Format-Place($result) {
    $a = $result.address
    $street = (([string]$a.road), ([string]$a.house_number) | Where-Object { $_ }) -join ' '
    $main = if ($result.name) { [string]$result.name } elseif ($a.house_number -and $a.road) { $street } else { '' }
    if (-not $main) { return (@(([string]$result.display_name).Split(',') | Select-Object -First 2 | ForEach-Object { $_.Trim() }) -join ', ') }
    $area = @($a.quarter, $a.suburb, $a.city_district, $a.district, $a.town, $a.village, $a.city | Where-Object { $_ -and $_ -ne $main })[0]
    ($main, $area | Where-Object { $_ }) -join ', '
}
