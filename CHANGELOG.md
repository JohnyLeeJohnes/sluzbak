# Changelog

Všechny podstatné změny v projektu. Formát vychází z [Keep a Changelog](https://keepachangelog.com/cs/1.1.0/),
verze se řídí [sémantickým verzováním](https://semver.org/lang/cs/).

## [Nevydáno]

### Přidáno

- Přehled okolí jednoho místa v Praze nad [Golemio API](https://api.golemio.cz/docs/openapi/):
  - odjezdy MHD ze zastávek do 600 m se zpožděním, zrušenými spoji a mimořádnostmi,
  - nejbližší lékárna, knihovna, úřad, služebna městské policie a sběrný dvůr s tím, jestli mají otevřeno,
  - tři nejbližší stanoviště tříděného odpadu se dny svozu, příštím svozem a zaplněním kontejnerů,
  - velkoobjemové kontejnery, které v okolí teprve přijedou,
  - index kvality ovzduší a naměřené látky z nejbližší stanice,
  - teplota, vlhkost, tlak, vítr a srážky z nejbližšího senzoru mikroklimatu,
  - nejbližší parkoviště a jejich volná místa.
- Nastavení při prvním spuštění: vlastní klíč k API a místo zadané adresou (hledá Nominatim) nebo souřadnicemi.
  Klíč se před uložením ověří.
- Volby v nastavení: které karty přehled ukazuje, okruh hledání zastávek, tříděného odpadu a parkovišť, počet
  odjezdů a interval jejich obnovování. Všechno má výchozí hodnotu a jde kdykoli změnit.
- Nastavení i volby se ukládají do `%APPDATA%\GolemWatch\settings.json`, klíč zašifrovaný přes Windows DPAPI. Stažená
  data se neukládají nikam.
- Odjezdy se obnovují každých 30 sekund, ostatní karty každých 10 minut; ručně tlačítkem Obnovit nebo F5.
- Chyba jedné karty nezastaví ostatní a ukáže se přímo v ní.
- Aplikace si hlídá limit API (20 dotazů za 8 sekund) a při jeho naplnění s dalším dotazem počká.
- Ukázková data pro náměstí Míru: tlačítko v nastavení a přepínač `-Demo`, obojí bez klíče i bez internetu.
- Přepínač `-Screenshot`, který uloží obrázek okna.
- Tmavý vzhled včetně titulkového pruhu okna.
- Ikona ve velikostech 16 až 256 px a `install.cmd`, který vytvoří zástupce v nabídce Start, na ploše
  a ve složce s aplikací.
- Testy čtení dat (`tests/unit.ps1`), test, který aplikaci prokliká přes UI Automation (`tests/e2e.ps1`),
  a zkouška naživo se skutečným klíčem (`tests/live.ps1`).

### Změněno

- Aplikace je skript v PowerShellu s oknem ve WPF místo původního projektu v C#. Nic se nekompiluje ani
  neinstaluje a nevadí jí Smart App Control, který sestavenou verzi na Windows 11 blokoval.

### Známé problémy

- Aplikace zatím neběžela proti skutečným datům z Golemia, jen proti ukázkovým odpovědím sestaveným podle
  specifikace API.
