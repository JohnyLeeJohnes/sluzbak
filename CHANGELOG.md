# Changelog

Všechny podstatné změny v projektu. Formát vychází z [Keep a Changelog](https://keepachangelog.com/cs/1.1.0/),
verze se řídí [sémantickým verzováním](https://semver.org/lang/cs/).

## [0.2.1] - 2026-10-05

### Změněno

- Aplikace si odpovědi z Golemia pamatuje a neptá se na ně zbytečně: měření, svozy, obsazenost a místa
  10 minut, odjezdy a polohy vozidel 10 sekund, číselníky a zastávky kolem místa po celou dobu běhu.
  Tlačítko **Obnovit**, F5, přepínání záložek ani uložení nastavení tak nestahují znovu, co je čerstvé.
  Paměť je jen v běžící aplikaci; na disk se dál nic neukládá.
- Kam vozidla jedou, se při startu doplní o pár sekund později, aby na tyhle dotazy nečekaly odjezdy
  a ostatní karty.
- Pravidelné obnovení karty se počítá od chvíle, kdy data dorazila.

### Opraveno

- Když Golemio dotaz odmítne kvůli limitu, aplikace počká a zkusí to znovu sama; dřív karta ukázala chybu.
- Na datové sady, ke kterým klíč nemá přístup, se aplikace neptá při každém obnovení.
- Uložení nastavení beze změny místa už znovu nestahuje celý seznam zastávek.

## [0.2.0] - 2026-10-05

Poprvé vyzkoušeno se skutečným klíčem; z toho většina změn níž.

### Přidáno

- Čtyři nové karty: **Právě jede kolem** (vozidla MHD do 1 km s cílem, směrem a zpožděním), **Výluky
  a mimořádnosti** (co PID hlásí v celé síti), **Sdílená auta** (nejbližší volná auta) a **Cyklosčítač**
  (kolik kol dnes projelo kolem nejbližšího sčítače).
- Karta V okolí ukazuje navíc nejbližší nemocnici, hřiště a zahradu; podrobnosti místa jsou v bublině.
- Parkování: vzdálenost k nejbližšímu parkovacímu automatu.
- V záhlaví přehledu je městská část, ve které místo leží.
- Přehled má dvě záložky, Doprava a Okolí. Stahuje se jen ta otevřená, takže přidané karty nezdržují.
- Hledání adresy: nalezená adresa se do pole vyplní sama, kliknutí na jinou v seznamu ji přepíše i se
  souřadnicemi. V seznamu jde vybírat šipkami přímo z pole s adresou.
- Když se spojení s Golemiem nepovede, dotaz se jednou zopakuje a karta to za půl minuty zkusí znovu sama.
- Přepínač `-Page`, který otevře danou záložku (k `-Screenshot`).
- Test klávesnice v nastavení (`tests/keys.ps1`).
- Licence MIT.

### Změněno

- Přehled je hustší a menší: obě záložky se vejdou do výchozího okna bez posouvání.
- Místo se jmenuje krátce („Korunní 586/2, Vinohrady“), ne celým řetězcem z vyhledávače.
- Svoz odpadu: druhy odpadu jsou seřazené podle toho, co se sveze nejdřív.
- Ovzduší: čerstvé hodnoty se berou z historie měření, protože seznam stanic vrací měsíce starý stav.
  Měření starší než 6 hodin se neukáže jako aktuální; karta místo něj napíše, z kdy je poslední.
- Mikroklima: bere se nejbližší senzor, který v posledních dvou hodinách něco naměřil, ne nejbližší vůbec.
  Když neměří žádný (od dubna 2026 všechny), karta to řekne rovnou.
- Velkoobjemové kontejnery se neukazují, když k nim klíč nemá přístup (dřív tam byla chybová hláška).
- Vzdálenost přesně na kilometry se píše „1 km“, ne „1,0 km“.

### Opraveno

- Hledání adresy: po kliknutí na **Najít** přestala v okně fungovat klávesnice a Enter v poli s adresou
  hledal pořád dokola. Teď první Enter hledá a druhý nalezenou adresu uloží.
- Karta, které Golemio napoprvé neodpovědělo včas, zůstala s chybou až do dalšího obnovení za deset minut.

### Známé problémy

- Běžný klíč z registrace nemá přístup k velkoobjemovým kontejnerům, sdíleným kolům, dopravním omezením,
  intenzitě dopravy, sčítačům chodců, hlášení závad ani k energetice. Kromě kontejnerů tyhle sady
  v aplikaci nejsou.

## [0.1.0] - 2026-10-05

První vydání. Číslo začíná nulou, protože aplikace ještě neběžela se skutečným klíčem (viz Známé problémy).

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
- ZIP ke stažení na stránce Releases: rozbalit, poklepat na `install.cmd` a je hotovo. Číslo verze je vidět
  dole na obrazovce nastavení.
- GolemWatch je skript v PowerShellu s oknem ve WPF, takže se nic nekompiluje ani neinstaluje a nevadí mu
  Smart App Control.

### Známé problémy

- Aplikace zatím neběžela proti skutečným datům z Golemia, jen proti ukázkovým odpovědím sestaveným podle
  specifikace API.

[0.2.1]: https://github.com/JohnyLeeJohnes/GolemWatch/releases/tag/v0.2.1
[0.2.0]: https://github.com/JohnyLeeJohnes/GolemWatch/releases/tag/v0.2.0
[0.1.0]: https://github.com/JohnyLeeJohnes/GolemWatch/releases/tag/v0.1.0
