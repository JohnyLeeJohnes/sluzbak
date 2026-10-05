# GolemWatch

Desktopová aplikace pro Windows nad pražským [Golemio API](https://api.golemio.cz/docs/openapi/). Uživatel zadá vlastní
API klíč a adresu (nebo souřadnice) a aplikace mu ukazuje, co se děje v okolí. Data se **nikam neukládají**, jen se
stahují a zobrazují. Vzorem je sesterský projekt Spáč (`C:\Projects\Personal\spac`).

## Stack

- Windows PowerShell 5.1 (ne pwsh 7) + WPF; okno je v XAML a načítá se přes `XamlReader`.
- Nic se nesestavuje a nejsou žádné závislosti. Z .NET Frameworku se používá `HttpClient`,
  `JavaScriptSerializer` a DPAPI (přes `ConvertFrom-SecureString`).
- Žádný linter ani formatter nastavený není.

## Konvence

- Komentáře a texty v UI česky (v UI tykání), commity anglicky.
- **Každý `.ps1` je UTF-8 s BOM.** Bez BOM čte PowerShell 5.1 soubor jako ANSI a rozbije češtinu. Hlídá to
  `tests/unit.ps1`. `.cmd` soubory jsou čistě ASCII.
- Funkce `Sloveso-Podstatné` (`Get-Waste`), proměnné camelCase, parametry skriptu PascalCase. Komentáře říkají *proč*.
- Každá funkce datové vrstvy dostává `$context = @{ Token; Demo; Limiter; Cache; Options }`: `Demo` je složka
  s ukázkovými odpověďmi místo sítě, `Limiter` fronta sdílená všemi úlohami pro hlídání limitu API, `Cache`
  sdílená paměť pro `Get-Cached` (číselníky, cíle spojů), `Options` volby uživatele.
- `Golemio.ps1` nemá o okně tušení. Funkce `Get-<Sekce>` vracejí `[pscustomobject]` připravený k zobrazení:
  hotové texty, barvy jako `#RRGGBB`, vždy `Meta` (text do záhlaví karty) a `Empty` (hláška místo dat, jinak `''`).
- Chyby z datové vrstvy: `throw (New-ApiError <druh> <česká hláška>)`; druh je v `Exception.Data['Kind']`
  (`Unauthorized`, `Forbidden`, `NotFound`, `RateLimited`, `Network`, `Unexpected`).
- **Síť nikdy ve vlákně okna.** `Start-Work` pustí funkci z `Golemio.ps1` v `RunspacePool`, časovač výsledek
  vyzvedne a zavolá obsluhu. Obsluha se předává **jménem funkce**, ne blokem: `GetNewClosure()` by neviděl
  funkce skriptu.
- Sekce přehledu drží pohromadě jméno: funkce `Get-<Sekce>`, v XAML prvky `<Sekce>Card`, `<Sekce>Meta`,
  `<Sekce>State`, `<Sekce>Body` a štítek `<Sekce>Chip` v nastavení. Data dostane karta přes `DataContext`.
- Záložky přehledu: `$pages` (`GolemWatch.ps1`, kopie v `tests/e2e.ps1`) říká, které sekce na které jsou;
  v XAML k záložce patří `<Záložka>Tab`, `<Záložka>Page` a sloupce `<Záložka>Column1` až `3`.
- Načítá se jen otevřená záložka: `Start-Due` pustí sekce, kterým vypršel termín v `$state.Due`. Sekce
  v `$live` se obnovují podle volby Refresh, ostatní po 10 minutách, po chybě spojení za 30 s.
- Volby uživatele: výchozí hodnoty v `$defaultOptions` (`Golemio.ps1`), meze v `$limits` (`GolemWatch.ps1`),
  pole `<Volba>Box` v nastavení. Datová vrstva je čte přes `Get-Option $context <jméno>`, nikdy napevno.
  `ConvertTo-Option` srovná cokoli (text z pole, hodnotu ze souboru) do mezí.
- Barvy jsou jen v paletě na začátku `GolemWatch.xaml`. Výjimka: barva titulku v `GolemWatch.ps1` (COLORREF)
  musí odpovídat `Bg`.

## Příkazy

```powershell
powershell -ExecutionPolicy Bypass -File GolemWatch.ps1            # spuštění (s konzolí)
powershell -ExecutionPolicy Bypass -File GolemWatch.ps1 -Demo      # ukázková data místo sítě
powershell -ExecutionPolicy Bypass -File GolemWatch.ps1 -Demo -Screenshot docs\prehled.png
powershell -ExecutionPolicy Bypass -File GolemWatch.ps1 -Demo -Page Around -Screenshot docs\okoli.png
powershell -ExecutionPolicy Bypass -File GolemWatch.ps1 -SettingsPath x.json -Screenshot docs\nastaveni.png
powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1       # ikona do assets/
powershell -ExecutionPolicy Bypass -File tools/make-release.ps1    # dist/GolemWatch-<verze>.zip
```

- `GolemWatch.cmd` spustí aplikaci bez konzole (`conhost --headless`), `install.cmd` vytvoří zástupce.
- `-SettingsPath` přesměruje nastavení mimo `%APPDATA%`; neexistující soubor = první spuštění.
- `-Screenshot` počká na načtení záložky (`-Page Traffic|Around`), natáhne okno na celý přehled, uloží PNG, skončí.

## Testy

```powershell
powershell -ExecutionPolicy Bypass -File tests/unit.ps1
powershell -ExecutionPolicy Bypass -File tests/e2e.ps1
powershell -ExecutionPolicy Bypass -File tests/keys.ps1
```

- `tests/unit.ps1` – datová vrstva nad `demo/`, formátování, chyby a varianty, kde si specifikace API protiřečí.
  Jeden test nejde pustit zvlášť; soubor je rychlý.
- `tests/e2e.ps1` – UI Automation: nastavení, hledání adresy, obě záložky, volby, chyba v jedné kartě. Otevírá
  skutečná okna. Schované prvky ve stromu zůstávají, viditelnost se pozná podle `IsOffscreen`.
- `tests/keys.ps1` – Enter, šipky, kliknutí na adresu a fokus v nastavení. Aplikaci načte do vlastního procesu
  a klávesy posílá jako události WPF (skutečné stisky by šly do okna uživatele). Fokus jde ověřit jen
  v aktivním okně; jinak ho přeskočí a napíše to.
- Všechny tři mají nastavení v dočasné složce, vracejí počet chyb a **nevolají síť**. Coverage se neměří.
- `tests/live.ps1` – zkouška naživo klíčem a místem z uloženého nastavení: co která karta dostala, u chyb
  zpracování i místo v kódu. Klíč nevypisuje.

## Struktura

```
GolemWatch.ps1    okno: stav, nastavení na disku, úlohy na pozadí, obsluhy událostí, -Install
GolemWatch.xaml   vzhled: paleta, styly, obrazovka nastavení a karty přehledu
Golemio.ps1       datová vrstva: HTTP, JSON, poloha a čas, jedna funkce na sekci, Find-Address, Test-Token
demo/             ukázkové odpovědi API (náměstí Míru), jméno souboru = cesta endpointu s pomlčkami
assets/           ikona (generuje tools/make-icon.ps1)
docs/             obrázky do README (generuje -Screenshot)
tests/, tools/
```

## Rozhodnutí a omezení

- **Větev je `master`**, ne `main`. Repozitář je na GitHubu soukromý a má to tak zůstat (rozhodnutí uživatele
  z 5. 10. 2026); Release proto stáhne jen ten, kdo má do repozitáře přístup. Licence je MIT.
- **Klíč nikdy do repozitáře.** Nastavení je v `%APPDATA%\GolemWatch\settings.json`, klíč šifrovaný DPAPI.
  Uživatel zmínil i „temp“; zůstává AppData, protože `%TEMP%` Windows při úklidu maže.
- Soubor s nastavením: `token`, `place`, `latitude`, `longitude`, `options` (`stopsRange`, `wasteRange`,
  `parkingRange`, `departures`, `refresh`, `hidden` = vypnuté sekce). Soubor bez `options` (starší verze) musí
  jít načíst dál; ukládají se vypnuté sekce, ne zapnuté, aby se nová karta po aktualizaci ukázala sama.
- Prázdný sloupec i záložku bez karet zavírá `Update-Layout`; karta se do jiného sloupce nestěhuje.
  Obě záložky se musí vejít do výchozího okna (1180×780) bez posouvání; nová karta = zkontrolovat obrázkem.
- **Žádné vlastní binárky.** Na vývojovém počítači (Windows 11 ARM64) je zapnutý Smart App Control a blokuje
  nepodepsané `.exe` i `.dll`, včetně těch právě sestavených (`0x800711C7`). Proto skript, ne C#.
  - `Add-Type` s C# kódem jen v `try/catch` a jen pro věci, bez kterých aplikace běží dál (tmavý titulek).
  - Nastavení Windows neměnit ani neobcházet; je to rozhodnutí uživatele.
- Pasti PowerShellu 5.1:
  - `ConvertFrom-Json` neunese odpověď nad 2 MB (seznam zastávek) → `ConvertFrom-ApiJson`;
  - `Invoke-RestMethod` bez charsetu rozbije diakritiku → bajty se dekódují ručně jako UTF-8;
  - čísla z JSON jsou `Decimal`, formátovat vždy s explicitní kulturou (`$cs`, `$invariant`);
  - `Where-Object vlastnost -eq …` nefunguje na slovnících z JSON, používat blok `{ $_.x -eq … }`;
  - typografické uvozovky `„` a `“` PowerShell bere jako konec řetězce: v `"…"` je nepoužívat.
- Golemio API:
  - hlavička `X-Access-Token`, nejvýš 10 000 řádků na požadavek;
  - limit 20 požadavků za 8 s na klíč: `Wait-RateLimit` jich pustí 18 a s dalším počká. První načtení záložky
    Doprava jich potřebuje přes 20, takže každá nová karta už znamená čekání;
  - první dotaz na některé endpointy trvá i přes 30 s (stanice ovzduší, cyklosčítače): `Invoke-Http` proto
    každý neúspěch jednou zopakuje;
  - endpointy míst (`/v2/medicalinstitutions` a podobné) podle `latlng` jen řadí, vzdálenost omezuje `range`;
  - `/v2/gtfs/stops` nemá filtr podle polohy: čte se celý seznam po stránkách, výsledek si okno pamatuje;
  - `/v3/parking` filtruje jen přes `boundingBox`, obsazenost je zvlášť v `/v3/parking-measurements`;
  - `/v1/bulky-waste/stations` má `range` v kilometrech (ostatní v metrech) a vlastnosti v camelCase;
  - `/v2/airqualitystations` vrací měsíce staré měření; čerstvé je v `…/history?from=` (jeden dotaz pro
    všechny stanice). Starší než `$airFreshHours` se jako aktuální neukazuje;
  - mikroklima: od 7. 4. 2026 nehlásí žádný senzor; `/v2/microclimate/measurements?from=` bez `pointId`
    vrátí všechny body naráz. Tlak chodí v Pa, veličiny mají v názvu výšku čidla (`air_temp200`);
  - polohy vozidel nemají cíl spoje (bere se z `/v2/public/gtfs/trips/{id}` přes `Get-Cached`), stejný
    infotext chodí zvlášť pro každou zastávku, vadný cyklosčítač hlásí celý den nuly;
  - **403 pro běžný klíč** (5. 10. 2026): `/v1/bulky-waste/stations`, `/v2/sharedbikes`, `/v2/vehiclesharing`,
    `/v2/traffic/restrictions`, `/v2/fcd/info`, chodci, `/v1/potholes/data`, energetika,
    `/v2/sortedwastestations/pickdays`, `/v3/pid/departurepresets`. Fronty na úřadech vracejí 404.
- Adresa se převádí na souřadnice přes Nominatim (vyžaduje vlastní `User-Agent`); okno na to upozorňuje.
  Jméno místa skládá `Format-Place` z `address` (`addressdetails=1`), protože `display_name` domu začíná číslem.
- Tlačítko **Najít** se během hledání nevypíná (vypnutý prvek ztratí fokus a klávesnice pak nedělá nic); hlídá
  to `$state.Finding`. Enter v poli adresy ukládá, když text sedí s `$state.Found`, jinak hledá.
- Ukázková data: `{{now+5}}` = čas za 5 minut, `{{day+1}}` = zítřejší datum, aby ukázka nezestárla.
  Testy na konkrétních hodnotách z `demo/` závisí, při úpravě souborů je pusť.
- Při chybě se data karty schovají schválně (prošlý odjezd nesmí vypadat jako aktuální).

## Nová karta

1. `Get-<Sekce>` v `Golemio.ps1` (vrací `Meta`, `Empty` a data) a ukázková odpověď v `demo/`.
2. Karta `<Sekce>Card` (s `Meta`, `State`, `Body`) a štítek `<Sekce>Chip` v `GolemWatch.xaml`.
3. Jméno do `$pages` v `GolemWatch.ps1` i v `tests/e2e.ps1`.
4. Testy v `tests/unit.ps1`, kontrola v `tests/e2e.ps1`, řádek v `tests/live.ps1` a v tabulce v README.

## Vydání

1. Zvyš `$version` v `GolemWatch.ps1`; v `CHANGELOG.md` přidej sekci `## [x.y.z] - datum` a odkaz dole.
2. Pusť `tests/unit.ps1` (hlídá, že obě čísla sedí), `tests/e2e.ps1` a `tests/keys.ps1`.
3. Commit `Release vX.Y.Z`, push, anotovaný tag `vX.Y.Z`, push tagu.
4. `tools/make-release.ps1` a `gh release create vX.Y.Z dist/GolemWatch-x.y.z.zip --title "GolemWatch x.y.z"`.
   Do poznámek patří postup z README (stáhnout, **odblokovat ZIP**, rozbalit, `install.cmd`).
- ZIP stažený prohlížečem nese značku „z internetu“ a Explorer ji přenese na rozbalené soubory. PowerShell
  s `-ExecutionPolicy Bypass` je spustí (ověřeno i se Smart App Control), poklepání na takový `.cmd` ale
  Windows brzdí. Proto krok „Odblokovat“ a `Unblock-File` v `-Install`.

## Stav a budoucnost

- Hotovo: nastavení (klíč, místo, volby), přehled se záložkami Doprava (Odjezdy, Právě jede kolem, Výluky,
  Parkování, Sdílená auta, Cyklosčítač) a Okolí (Svoz odpadu, V okolí, Ovzduší, Mikroklima), městská část
  v záhlaví, ukázkový režim, hlídání limitu API.
- **Ověřeno naživo** klíčem uživatele 5. 10. 2026 (`tests/live.ps1`, všech deset karet). Neověřené zůstává, co
  API nevrátilo: velkoobjemové kontejnery (403) a karta Mikroklima s daty (senzory mlčí).
- Kde se živé API liší od specifikace, bere kód obě varianty: `AQ_hourly_index` (naživo kód „1A“, ne číslo),
  `/v2/microclimate/points` (naživo pole s `point_name`), pozice zabalená do pole navíc. Číselníky ovzduší
  v `demo/` jsou opsané z živého API.
- Neověřeno: stažení ZIPu prohlížečem a poklepání v Exploreru nikdo nezkoušel; ověřené je
  rozbalení ZIPu do čisté složky a spuštění přes `GolemWatch.cmd` bez značky „z internetu“.
- Plán: uživatel chce z Golemia všechno. Co běžný klíč smí, je použité; zbytek čeká na přístup (seznam 403
  výše, žádá se na golemio@operatorict.cz).

## Minulé úpravy

Viz `CHANGELOG.md` a `git log`. První verze byla v C# (.NET 10, Avalonia, pak WPF; commit `3c1d580`). Kvůli
Smart App Control nešla na vývojovém počítači spustit, proto přepis do PowerShellu.
