<p align="center">
  <img src="assets/golemwatch.png" width="96" alt="Ikona aplikace GolemWatch">
</p>

<h1 align="center">GolemWatch</h1>

<p align="center">
  Praha kolem tebe na jedné obrazovce: odjezdy MHD, svoz odpadu, ovzduší a parkování.
</p>

<p align="center">
  <img src="docs/prehled.png" width="860" alt="Přehled: odjezdy, místa v okolí, svoz odpadu, ovzduší, mikroklima a parkování">
</p>

Zadáš svůj klíč ke [Golemio API](https://api.golemio.cz/docs/openapi/) a adresu. GolemWatch pak ukazuje, co se
děje v okolí, a sám se obnovuje.

- **Nic se neinstaluje ani nekompiluje.** Skript v PowerShellu a okno v XAML. Všechno, co potřebuje, už ve
  Windows je.
- **Data se nikam neukládají.** Aplikace je jen stáhne a ukáže. Na disku má jediný soubor s nastavením.
- **Klíč zůstává u tebe.** Ukládá se zašifrovaný a posílá se jen na `api.golemio.cz`.
- **Jde to zkusit i bez klíče.** Tlačítko **Zkusit s ukázkovými daty** ukáže přehled pro náměstí Míru
  s vymyšlenými daty, bez internetu.

> **Stav:** aplikace je napsaná podle specifikace API a vyzkoušená na ukázkových datech. Proti skutečným
> datům z Golemia zatím neběžela, protože při vývoji nebyl k dispozici klíč. Kdyby se některá karta se
> skutečným klíčem chovala divně, je to nejspíš místo, kde se API liší od své specifikace.

## Co ukazuje

| Karta | Co v ní je | Odkud |
| --- | --- | --- |
| Odjezdy | nejbližší odjezdy ze zastávek do 600 m, zpoždění, zrušené spoje, mimořádnosti | `/v2/gtfs/stops`, `/v2/pid/departureboards` |
| V okolí | nejbližší lékárna, knihovna, úřad, služebna městské policie a sběrný dvůr, s otevírací dobou | `/v2/medicalinstitutions`, `/v2/municipallibraries`, `/v2/municipalauthorities`, `/v2/municipalpolicestations`, `/v2/wastecollectionyards` |
| Svoz odpadu | tři nejbližší stanoviště tříděného odpadu do 400 m, dny svozu, příští svoz, zaplnění podle senzoru | `/v2/sortedwastestations` |
| | velkoobjemové kontejnery do 1,5 km, které teprve přijedou | `/v1/bulky-waste/stations` |
| Ovzduší | index kvality a naměřené látky z nejbližší stanice ČHMÚ | `/v2/airqualitystations` |
| Mikroklima | teplota, vlhkost, tlak, vítr a srážky z nejbližšího městského senzoru | `/v2/microclimate/points`, `/v2/microclimate/measurements` |
| Parkování | šest nejbližších parkovišť do 1,5 km a volná místa, kde se měří | `/v3/parking`, `/v3/parking-measurements` |

Vzdálenosti v tabulce jsou výchozí; okruh pro zastávky, tříděný odpad a parkoviště si v nastavení změníš,
stejně jako to, které karty chceš vidět.

Odjezdy se obnovují každých 30 sekund (jde změnit), všechno ostatní každých 10 minut. Hned to jde tlačítkem
**Obnovit** nebo klávesou F5. Minimalizované okno nic nestahuje a po návratu se obnoví hned.

## Instalace

1. Na stránce [Releases](https://github.com/JohnyLeeJohnes/GolemWatch/releases/latest) stáhni
   `GolemWatch-<verze>.zip`.
2. Klikni na stažený ZIP pravým tlačítkem, zvol **Vlastnosti**, dole zaškrtni **Odblokovat** a potvrď.
3. Rozbal ho tam, kde má aplikace zůstat, třeba do Dokumentů.
4. Ve složce `GolemWatch` poklepej na **`install.cmd`**. Vytvoří zástupce **GolemWatch** s ikonou v nabídce
   Start, na ploše a přímo ve složce. Přes něj se aplikace spouští jako každá jiná, bez okna konzole.

> **Proč odblokovat?** Windows si soubory stažené z internetu označí a u skriptů s tímhle označením se ptá,
> jestli je má spustit, nebo je rovnou odmítne (Smart App Control ve Windows 11). Když ZIP odblokuješ ještě
> před rozbalením, označení se na rozbalené soubory nepřenese.

- **Jen vyzkoušet:** poklepej na `GolemWatch.cmd`, spustí aplikaci bez vytváření zástupců.
- **Nová verze:** stáhni ji stejně a rozbal přes tu starou. Nastavení zůstane, je uložené jinde. Kterou
  verzi máš, je napsané dole na obrazovce nastavení.
- **Přesunutí složky:** zástupce ukazuje tam, kde aplikace leží. Po přesunutí spusť `install.cmd` znovu.
- **Odebrání:** smaž zástupce z plochy a z nabídky Start, celou složku a `%APPDATA%\GolemWatch`.
- **Z gitu:** `git clone https://github.com/JohnyLeeJohnes/GolemWatch.git` a pak rovnou krok 4. Klonování
  označení z internetu nepřidává, takže odblokování odpadá.

Potřebuješ Windows 10 nebo 11 (Windows PowerShell 5.1 je jejich součástí). Vyzkoušeno na Windows 11.

## První spuštění

<p align="center">
  <img src="docs/nastaveni.png" width="860" alt="Nastavení: klíč, místo a volby">
</p>

1. **Klíč.** Zdarma po registraci na [api.golemio.cz/api-keys](https://api.golemio.cz/api-keys). Než se
   uloží, aplikace si ho u Golemia ověří.
2. **Místo.** Napiš adresu a dej **Najít**, nebo vyplň souřadnice ručně (projde `50.0753` i `50,0753`).
   Text v poli s adresou se zároveň použije jako název místa v přehledu.
3. **Volby.** Nic z toho vyplňovat nemusíš, všechno má výchozí hodnotu:
   - které karty má přehled ukazovat (vypnutá karta se ani nestahuje),
   - jak daleko hledat zastávky (100–2000 m), tříděný odpad (100–2000 m) a parkoviště (200–5000 m),
   - kolik odjezdů ukázat (3–30) a jak často je obnovovat (15–600 s).

Aplikace si všechno pamatuje a příště otevře rovnou přehled. Změníš to kdykoli tlačítkem **Nastavení**
v přehledu.

## Dobré vědět

- **Co kam odchází.** Klíč a souřadnice jdou jen na `api.golemio.cz`. Adresa, kterou hledáš, jde službě
  [Nominatim](https://nominatim.openstreetmap.org/) (OpenStreetMap), a to jen po kliknutí na **Najít**.
  Když souřadnice vyplníš ručně, nikam jinam se nic neposílá.
- **Kde je nastavení.** V `%APPDATA%\GolemWatch\settings.json`: klíč, název místa, souřadnice a volby. Klíč
  šifruje Windows (DPAPI), takže ho přečte jen tvůj účet na tomhle počítači. Na jiném počítači ho zadáš znovu.
  Dočasná složka (`%TEMP%`) by nestačila: Windows ji při úklidu maže a aplikace by nastavení zapomněla.
- **Limit API.** Golemio dovoluje 20 dotazů za 8 sekund na jeden klíč. První načtení přehledu jich potřebuje
  skoro tolik, obnovení odjezdů jeden. Aplikace si dotazy počítá a když by limit překročila, chvilku počká.
- **První hledání zastávek chvíli trvá.** API neumí vrátit zastávky podle polohy, takže se jednou po spuštění
  stáhne jejich celý seznam.
- **Když karta selže, ostatní jedou dál.** Chyba se ukáže přímo v kartě. Stará data se při chybě schovají,
  aby prošlý odjezd nevypadal jako aktuální.
- **Časy odjezdů, svozů a měření jsou pražské,** ať je počítač nastavený jakkoli.
- **Proč skript, a ne `.exe`.** Nepodepsaný `.exe` umí Windows 11 (Smart App Control) zablokovat. Skript
  běží bez podpisu a před spuštěním si ho můžeš celý přečíst.

## Úpravy

| Soubor | Obsah |
| --- | --- |
| `GolemWatch.ps1` | Chování okna: nastavení, načítání na pozadí, obnovování, vytvoření zástupců. |
| `GolemWatch.xaml` | Vzhled okna: barvy, styly, karty. |
| `Golemio.ps1` | Čtení dat z Golemio API a hledání adres. Bez okna, dá se zkoušet samostatně. |
| `demo/` | Ukázkové odpovědi API pro náměstí Míru. |
| `GolemWatch.cmd`, `install.cmd` | Spuštění bez instalace a vytvoření zástupců. |
| `tools/make-icon.ps1` | Vygeneruje ikonu do `assets/`. |
| `tools/make-release.ps1` | Sestaví ZIP pro stránku Releases do `dist/`. |
| `tests/unit.ps1` | Testy čtení dat nad ukázkovými odpověďmi. |
| `tests/e2e.ps1` | Test, který aplikaci prokliká přes UI Automation. |
| `tests/live.ps1` | Zkouška naživo: načte všechny karty ze skutečného API a vypíše, co která dostala. |

Chceš jiné barvy? Celá paleta je na začátku `GolemWatch.xaml`. Změny se projeví při dalším spuštění, nic se
nesestavuje.

Testy se pouští takhle:

```
powershell -ExecutionPolicy Bypass -File tests/unit.ps1
```

```
powershell -ExecutionPolicy Bypass -File tests/e2e.ps1
```

Ani jeden nevolá síť a nepotřebuje klíč. Druhý během běhu několikrát otevře a zavře okno aplikace a pracuje
s nastavením v dočasné složce, takže na to tvoje nesáhne.

Se skutečným klíčem jde všechno projít naráz. Skript si klíč a místo vezme z nastavení aplikace, takže ji
nejdřív jednou spusť a nastav:

```
powershell -ExecutionPolicy Bypass -File tests/live.ps1
```

U každé karty vypíše, kolik čeho dostala, nebo chybu. Klíč nevypisuje.

Aplikace jde pustit i s ukázkovými daty místo sítě a umí uložit obrázek svého okna:

```
powershell -ExecutionPolicy Bypass -File GolemWatch.ps1 -Demo
```

```
powershell -ExecutionPolicy Bypass -File GolemWatch.ps1 -Demo -Screenshot docs\prehled.png
```

Změny se zapisují do [CHANGELOG.md](CHANGELOG.md).

## Licence

[MIT](LICENSE)

---

**In English:** GolemWatch is a small Windows desktop dashboard on top of Prague's Golemio open-data API. Enter
your own API key and an address, and it shows nearby public-transport departures, waste collection days, air
quality, microclimate sensors and parking. It is a PowerShell script with a WPF window: download the ZIP from
the Releases page, unblock and extract it, and run `install.cmd` to get a shortcut. Nothing to compile or install. Nothing is stored except your settings. The
interface is in Czech.
