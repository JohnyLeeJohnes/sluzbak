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
- Funkce se jmenují `Sloveso-Podstatné` (`Get-Waste`, `Show-State`), proměnné camelCase, parametry skriptu PascalCase.
- Komentáře vysvětlují *proč*, ne *co*.
- Každá funkce datové vrstvy dostává `$context = @{ Token; Demo; Limiter; Options }`: `Demo` je složka
  s ukázkovými odpověďmi místo sítě, `Limiter` fronta sdílená všemi úlohami pro hlídání limitu API, `Options`
  volby uživatele.
- `Golemio.ps1` nemá o okně tušení. Funkce `Get-<Sekce>` vracejí `[pscustomobject]` připravený k zobrazení:
  hotové texty, barvy jako `#RRGGBB`, vždy `Meta` (text do záhlaví karty) a `Empty` (hláška místo dat, jinak `''`).
- Chyby z datové vrstvy: `throw (New-ApiError <druh> <česká hláška>)`; druh je v `Exception.Data['Kind']`
  (`Unauthorized`, `Forbidden`, `NotFound`, `RateLimited`, `Network`, `Unexpected`).
- **Síť nikdy ve vlákně okna.** `Start-Work` pustí funkci z `Golemio.ps1` v `RunspacePool`, časovač výsledek
  vyzvedne a zavolá obsluhu. Obsluha se předává **jménem funkce**, ne blokem: `GetNewClosure()` by neviděl
  funkce skriptu.
- Sekce přehledu drží pohromadě jméno: funkce `Get-<Sekce>`, v XAML prvky `<Sekce>Card`, `<Sekce>Meta`,
  `<Sekce>State`, `<Sekce>Body` a štítek `<Sekce>Chip` v nastavení, položka v `$sections`. Karta dostane data
  přes `DataContext`, vazby v XAML čtou vlastnosti objektu.
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
powershell -ExecutionPolicy Bypass -File GolemWatch.ps1 -SettingsPath x.json -Screenshot docs\nastaveni.png
powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1       # ikona do assets/
powershell -ExecutionPolicy Bypass -File tools/make-release.ps1    # dist/GolemWatch-<verze>.zip
```

- `GolemWatch.cmd` spustí aplikaci bez konzole (`conhost --headless`), `install.cmd` vytvoří zástupce.
- `-SettingsPath` přesměruje nastavení mimo `%APPDATA%`; neexistující soubor = první spuštění.
- `-Screenshot` počká na načtení, natáhne okno na celý přehled, uloží PNG a skončí.

## Testy

```powershell
powershell -ExecutionPolicy Bypass -File tests/unit.ps1
powershell -ExecutionPolicy Bypass -File tests/e2e.ps1
```

- `tests/unit.ps1` – datová vrstva nad `demo/`, formátování, chyby a varianty, kde si specifikace API protiřečí.
  Jeden test nejde pustit zvlášť; soubor je rychlý.
- `tests/e2e.ps1` – UI Automation: první spuštění, validace, hledání adresy, uložení, načtení nastavení, chyba
  v jedné kartě. Otevírá skutečná okna, nastavení má v dočasné složce.
- Oba vracejí počet chyb jako návratový kód a **nevolají síť**. Coverage se neměří.
- `tests/live.ps1` – zkouška naživo: klíč a místo z uloženého nastavení aplikace, vypíše, co která karta
  dostala, u chyb zpracování i místo v kódu. Volá skutečné API; klíč nevypisuje. Pouští ji uživatel.
- V e2e: schované prvky ve stromu zůstávají, viditelnost se pozná podle `IsOffscreen`.

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

- **Větev je `master`**, ne `main`. Repozitář je na GitHubu soukromý.
- **Klíč nikdy do repozitáře.** Nastavení je v `%APPDATA%\GolemWatch\settings.json`, klíč šifrovaný DPAPI.
  Uživatel zmínil i „temp“; zůstává AppData, protože `%TEMP%` Windows při úklidu maže.
- Soubor s nastavením: `token`, `place`, `latitude`, `longitude`, `options` (`stopsRange`, `wasteRange`,
  `parkingRange`, `departures`, `refresh`, `hidden` = vypnuté sekce). Soubor bez `options` (starší verze) musí
  jít načíst dál; ukládají se vypnuté sekce, ne zapnuté, aby se nová karta po aktualizaci ukázala sama.
- Prázdný sloupec přehledu zavírá `Update-Layout`; karta se do jiného sloupce nestěhuje.
- **Žádné vlastní binárky.** Na vývojovém počítači (Windows 11 ARM64) je zapnutý Smart App Control a blokuje
  nepodepsané `.exe` i `.dll`, včetně těch právě sestavených (`0x800711C7`). Proto skript, ne C#.
  - `Add-Type` s C# kódem jen v `try/catch` a jen pro věci, bez kterých aplikace běží dál (tmavý titulek).
  - Nastavení Windows neměnit ani neobcházet; je to rozhodnutí uživatele.
- Pasti PowerShellu 5.1:
  - `ConvertFrom-Json` neunese odpověď nad 2 MB (seznam zastávek) → `ConvertFrom-ApiJson`;
  - `Invoke-RestMethod` bez charsetu rozbije diakritiku → bajty se dekódují ručně jako UTF-8;
  - čísla z JSON jsou `Decimal`, formátovat vždy s explicitní kulturou (`$cs`, `$invariant`);
  - `Where-Object vlastnost -eq …` nefunguje na slovnících z JSON, používat blok `{ $_.x -eq … }`.
- Golemio API:
  - hlavička `X-Access-Token`, nejvýš 10 000 řádků na požadavek;
  - limit 20 požadavků za 8 s na klíč: `Wait-RateLimit` jich pustí 18 a s dalším počká. První načtení přehledu
    jich potřebuje kolem 18, takže každá nová karta už znamená čekání;
  - endpointy míst (`/v2/medicalinstitutions` a podobné) podle `latlng` jen řadí, vzdálenost omezuje `range`;
  - `/v2/gtfs/stops` nemá filtr podle polohy: čte se celý seznam po stránkách, výsledek si okno pamatuje;
  - `/v3/parking` filtruje jen přes `boundingBox`, obsazenost je zvlášť v `/v3/parking-measurements`;
  - `/v1/bulky-waste/stations` má `range` v kilometrech (ostatní v metrech) a vlastnosti v camelCase.
- Adresa se převádí na souřadnice přes Nominatim (vyžaduje vlastní `User-Agent`); okno na to upozorňuje.
- Ukázková data: `{{now+5}}` = čas za 5 minut, `{{day+1}}` = zítřejší datum, aby ukázka nezestárla.
  Testy na konkrétních hodnotách z `demo/` závisí, při úpravě souborů je pusť.
- Při chybě se data karty schovají schválně (prošlý odjezd nesmí vypadat jako aktuální).

## Nová karta

1. `Get-<Sekce>` v `Golemio.ps1` (vrací `Meta`, `Empty` a data) a ukázková odpověď v `demo/`.
2. Karta `<Sekce>Card` v `GolemWatch.xaml` s prvky `<Sekce>Meta`, `<Sekce>State`, `<Sekce>Body` a štítek
   `<Sekce>Chip` v nastavení.
3. Jméno do `$sections` v `GolemWatch.ps1`.
4. Testy v `tests/unit.ps1` a kontrola v `tests/e2e.ps1`, řádek do tabulky v README.

## Vydání

1. Zvyš `$version` v `GolemWatch.ps1`; v `CHANGELOG.md` přidej sekci `## [x.y.z] - datum` a odkaz dole.
2. Pusť `tests/unit.ps1` (hlídá, že obě čísla sedí) a `tests/e2e.ps1`.
3. Commit `Release vX.Y.Z`, push, anotovaný tag `vX.Y.Z`, push tagu.
4. `tools/make-release.ps1` a `gh release create vX.Y.Z dist/GolemWatch-x.y.z.zip --title "GolemWatch x.y.z"`.
   Do poznámek patří postup z README (stáhnout, **odblokovat ZIP**, rozbalit, `install.cmd`).
- ZIP stažený prohlížečem nese značku „z internetu“ a Explorer ji přenese na rozbalené soubory. PowerShell
  s `-ExecutionPolicy Bypass` takové skripty spustí (ověřeno i se Smart App Control), poklepání na `.cmd`
  s touhle značkou ale Windows brzdí. Proto krok „Odblokovat“ a `Unblock-File` v `-Install`.

## Stav a budoucnost

- Hotovo: nastavení (klíč, místo, volby), přehled s kartami Odjezdy, V okolí, Svoz odpadu, Ovzduší,
  Mikroklima, Parkování, ukázkový režim, hlídání limitu API.
- **Neověřeno proti živému API s platným klíčem** – při vývoji žádný nebyl. Ověřeno je jen, že neplatný klíč
  vrátí 401 a že funguje hledání přes Nominatim. První krok po získání klíče: `tests/live.ps1`.
- Sporná místa specifikace, kde kód bere obě varianty: `AQ_hourly_index` (číslo vs. kód „1A“),
  `/v2/microclimate/points` (objekt vs. pole), `point_named` vs. `point_name`, pozice zabalená do pole navíc.
- Chybí: soubor s licencí. Stažení ZIPu prohlížečem a poklepání v Exploreru nikdo nezkoušel; ověřené je
  rozbalení ZIPu do čisté složky a spuštění přes `GolemWatch.cmd` bez značky „z internetu“.
- Plán: další datasety z Golemia (uživatel chce časem všechny). Zatím nepoužité: sdílená kola a auta
  (`/v2/vehiclesharing`), zahrady a hřiště, dopravní omezení (`/v2/traffic/restrictions`), polohy vozidel
  (`/v2/public/vehiclepositions`), cyklosčítače, energetika.

## Minulé úpravy

Viz `CHANGELOG.md` a `git log`. První verze byla v C# (.NET 10, Avalonia, pak WPF; commit `3c1d580`). Kvůli
Smart App Control nešla na vývojovém počítači spustit, proto přepis do PowerShellu.
