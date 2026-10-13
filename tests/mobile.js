// Zkouška datové vrstvy mobilního Službáka (mobile/data.js):
//   node tests/mobile.js
//
// Nad ukázkovými daty ze složky demo musí telefon ukázat totéž co počítač: každou kartu spočítá Golemio.ps1
// i data.js a výsledky se porovnají. Kde není PowerShell (mimo Windows), se porovnání přeskočí. Síť tu zastupuje
// vlastní fetch s počítadlem, takže se nikam nevolá. Stránku samotnou nezkouší.
'use strict';
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const golemio = require('../mobile/data.js');

const root = path.join(__dirname, '..');
const lat = 50.0753, lng = 14.4379;   // náměstí Míru

let fail = 0;
function check(what, actual, expected) {
    if (String(actual) === String(expected)) console.log(`ok    ${what}`);
    else {
        fail++;
        console.log(`FAIL  ${what} = '${actual}' (čekáno '${expected}')`);
    }
}
async function errorKind(action) {
    try { await action(); return '<bez chyby>'; }
    catch (error) { return String(error.kind); }
}

// Ukázkové soubory čte ze složky demo; patches některé cestou přepíše (funkce z textu udělá jiný) nebo skryje (null).
function readFrom(patches = {}) {
    return async file => {
        let text = null;
        try { text = fs.readFileSync(path.join(root, 'demo', file), 'utf8').replace(/^﻿/, ''); }
        catch { }
        return file in patches ? patches[file] && patches[file](text) : text;
    };
}
const demo = { token: '', demo: readFrom() };

// ---- Porovnání s počítačem ----

const sections = ['transit', 'vehicles', 'waste', 'alerts', 'cars', 'cycling', 'air', 'weather', 'parking', 'nearby'];
const cases = [
    { name: 'náměstí Míru', options: {}, lat, lng },
    { name: 'užší okruhy', options: { stopsRange: 300, wasteRange: 100, parkingRange: 600, departures: 4 }, lat, lng },
    { name: 'mimo Prahu', options: {}, lat: 49, lng: 13 },
];

async function compute() {
    const all = {};
    for (const one of cases) {
        const context = { ...demo, options: one.options };
        const cards = {};
        for (const name of sections) {
            const get = golemio[`get${name[0].toUpperCase()}${name.slice(1)}`];
            try { cards[name] = await get(context, one.lat, one.lng, null); }
            catch (error) { cards[name] = { error: String(error.kind) }; }
        }
        cards.district = await golemio.getDistrict(context, one.lat, one.lng);
        all[one.name] = cards;
    }
    all.address = await golemio.findAddress(demo, 'náměstí Míru');
    return all;
}

// Počítač píše jména vlastností velkým písmenem a pár si jich nechává jen na řazení (datum, metry).
function normalize(value) {
    if (Array.isArray(value)) return value.map(normalize);
    if (value === null || typeof value !== 'object') return value;
    const result = {};
    for (const key of Object.keys(value)) {
        const name = key[0].toLowerCase() + key.slice(1);
        if (value[key] != null && !['day', 'meters'].includes(name)) result[name] = normalize(value[key]);
    }
    return result;
}

// První místo, kde se dvě hodnoty liší; nic, když jsou stejné.
function difference(actual, expected, where = '') {
    if (actual !== null && expected !== null && typeof actual === 'object' && typeof expected === 'object') {
        for (const key of new Set([...Object.keys(actual), ...Object.keys(expected)])) {
            const found = difference(actual[key], expected[key], `${where}.${key}`);
            if (found) return found;
        }
        return null;
    }
    return actual === expected ? null : `${where} = ${JSON.stringify(actual)} (počítač ${JSON.stringify(expected)})`;
}

function runPowerShell(temp) {
    const quote = text => `'${text.replace(/'/g, "''")}'`;
    // Skript má BOM a výsledek píše do souboru: kódová stránka konzole by češtinu cestou pokazila.
    fs.writeFileSync(path.join(temp, 'cards.ps1'), String.fromCharCode(0xFEFF) + `
        $ErrorActionPreference = 'Stop'
        . ${quote(path.join(root, 'Golemio.ps1'))}
        [Threading.Thread]::CurrentThread.CurrentCulture = 'cs-CZ'
        $demo = ${quote(path.join(root, 'demo'))}
        $cases = @(
            @{ Name = 'náměstí Míru'; Options = @{}; Latitude = 50.0753; Longitude = 14.4379 }
            @{ Name = 'užší okruhy'; Options = @{ StopsRange = 300; WasteRange = 100; ParkingRange = 600; Departures = 4 }; Latitude = 50.0753; Longitude = 14.4379 }
            @{ Name = 'mimo Prahu'; Options = @{}; Latitude = 49.0; Longitude = 13.0 }
        )
        $all = [ordered]@{}
        foreach ($case in $cases) {
            $context = @{ Token = ''; Demo = $demo; Options = $case.Options }
            $cards = [ordered]@{}
            foreach ($name in ${sections.map(quote).join(', ')}) {
                $arguments = @($context, $case.Latitude, $case.Longitude)
                if ($name -eq 'transit') { $arguments += , $null }
                $cards[$name] = try { & "Get-$name" @arguments } catch { @{ Error = [string]$_.Exception.Data['Kind'] } }
            }
            $cards.district = [string](Get-District $context $case.Latitude $case.Longitude)
            $all[$case.Name] = $cards
        }
        $all.address = @(Find-Address @{ Demo = $demo } 'náměstí Míru')
        [IO.File]::WriteAllText("$PSScriptRoot\\cards.json", ($all | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    `);
    return new Promise((resolve, reject) => {
        execFile('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(temp, 'cards.ps1')], (error, stdout, stderr) => {
            if (error?.code === 'ENOENT') resolve(null);
            else if (error) reject(new Error(`PowerShell: ${stderr || stdout || error.message}`));
            else resolve(JSON.parse(fs.readFileSync(path.join(temp, 'cards.json'), 'utf8')));
        });
    });
}

async function compareWithDesktop() {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'sluzbak-mobile-'));
    try {
        // Ukázka počítá časy od teď. Kdyby se mezi oběma výpočty přehoupla minuta, lišily by se o ni: telefon proto
        // počítá před počítačem i po něm a stačí shoda s jedním z obou výsledků.
        const before = normalize(await compute());
        const desktop = await runPowerShell(temp);
        if (!desktop) {
            console.log('skip  porovnání s Golemio.ps1: PowerShell tu není');
            return;
        }
        const after = normalize(await compute());
        const expected = normalize(desktop);
        for (const one of cases) {
            for (const name of [...sections, 'district']) {
                const found = difference(before[one.name][name], expected[one.name][name]) && difference(after[one.name][name], expected[one.name][name]);
                check(`${one.name}: ${name} jako na počítači`, found ?? 'stejné', 'stejné');
            }
        }
        check('nalezené adresy jako na počítači', difference(before.address, expected.address) ?? 'stejné', 'stejné');
    }
    finally { fs.rmSync(temp, { recursive: true, force: true }); }
}

async function main() {
    console.log('--- dotazy a formátování');
    check('dotaz', golemio.formatQuery({ latlng: '50.0755,14.4378', range: 300, limit: null, 'ids[]': ['U1 Z', 'U2'], flag: true, half: 1.5 }),
        '?latlng=50.0755%2C14.4378&range=300&ids%5B%5D=U1%20Z&ids%5B%5D=U2&flag=true&half=1.5');
    check('prázdný dotaz', golemio.formatQuery({}), '');
    check('souřadnice s tečkou', golemio.formatLatLng(50.0755, 14.43781234), '50.0755,14.437812');
    check('stupeň šířky v metrech', Math.round(golemio.getDistance(50, 14, 51, 14)), 111195);
    check('vzdálenost pod 1 km', golemio.formatDistance(123), '120 m');
    check('vzdálenost těsně pod 1 km', golemio.formatDistance(994), '990 m');
    check('vzdálenost nad 1 km', golemio.formatDistance(1234), '1,2 km');
    check('bounding box', /^50\.08\d+,14\.41\d+,50\.06\d+,14\.45\d+$/.test(golemio.getBoundingBox(lat, lng, 1500)), true);
    check('číslo česky', golemio.formatNumber(38.44), '38,4');
    check('tisíce s pevnou mezerou', golemio.formatNumber(2801, '#,0'), '2\xa0801');
    check('půlky k sudému jako na počítači', [0.5, 1.5, 2.5, -1.5, 2.4].map(golemio.round).join(' '), '0 2 2 -2 2');
    check('vzorec NO2', golemio.formatFormula('NO2'), 'NO₂');
    check('vzorec PM2_5', golemio.formatFormula('PM2_5'), 'PM2,5');
    check('světové strany', [0, 44, 90, 135, 200, 225, 265, 315, 359, -90].map(golemio.formatCompass).join(' '), 'S SV V JV J JZ Z SZ S Z');
    check('bez azimutu nic', `${golemio.formatCompass(null)}|${golemio.formatCompass('')}|`, '||');

    console.log('--- poloha a čas');
    const position = golemio.readPosition([14.4, 50.1]);
    check('bod', `${position.latitude} ${position.longitude}`, '50.1 14.4');
    check('polygon: první vrchol', golemio.readPosition([[[14.4, 50.1], [14.5, 50.2]]]).longitude, 14.4);
    check('prázdná, chybějící a nesmyslná pozice', [[], null, [14.4, 950]].map(golemio.readPosition).join(), ',,');
    const today = golemio.getPragueDay(new Date());
    check('dnes a zítra', `${golemio.formatDay(today)} ${golemio.formatDay(new Date(today.getTime() + 86400000))}`, 'dnes zítra');
    check('jiný den', /^(po|út|st|čt|pá|so|ne) \d{1,2}\. \d{1,2}\.$/.test(golemio.formatDay(new Date(today.getTime() + 3 * 86400000))), true);
    check('datum bez času', golemio.convertToDay('2026-10-07').toISOString().slice(0, 10), '2026-10-07');
    check('UTC na pražský čas v létě i v zimě', ['2026-07-01T07:05:00.000Z', '2026-01-01T07:05:00'].map(text => golemio.formatClock(golemio.convertToPragueTime(text))).join(' '), '9:05 8:05');
    check('den podle Prahy, ne podle UTC', golemio.convertToDay('2026-07-01T22:30:00Z').toISOString().slice(0, 10), '2026-07-02');
    check('nesmyslný čas', golemio.convertToPragueTime('string'), null);
    check('bod uvnitř a vedle obrysu', [2, 5].map(longitude => golemio.testInRing([[0, 0], [4, 0], [4, 4], [0, 4]], 2, longitude)).join(' '), 'true false');

    console.log('--- chyby');
    check('druhy chyb', [401, 403, 404, 429, 500].map(status => golemio.convertToApiError(status).kind).join(' '), 'Unauthorized Forbidden NotFound RateLimited Unexpected');
    check('chybějící ukázkový soubor', await errorKind(() => golemio.invokeApi(demo, '/v9/neexistuje')), 'NotFound');

    console.log('--- karty');
    // Odmítnutí kvůli limitu čeká celé okno limitu (8 s). Běží proto vedle porovnání s počítačem a vyhodnotí se až dole.
    let calls = [];
    const reject = { once: 1, twice: 2 };   // kolikrát server dotaz odmítne kvůli limitu
    const vehiclePositions = await golemio.invokeApi(demo, '/v2/public/vehiclepositions');
    globalThis.fetch = async uri => {
        const reply = (status, body) => ({ ok: status < 400, status, text: async () => JSON.stringify(body) });
        const limited = /\/limited\/(\w+)/.exec(uri)?.[1];
        if (reject[limited] > 0) { reject[limited]--; return reply(429, {}); }
        // Druhé pokusy odmítnutých dotazů přijdou kdykoli během dalších zkoušek; do jejich počítání nepatří.
        if (!limited) calls.push(uri);
        if (uri.includes('/forbidden')) return reply(403, {});
        if (uri.includes('/vehiclepositions')) return reply(200, vehiclePositions);
        const trip = /\/gtfs\/trips\/([^?]+)/.exec(uri);
        return reply(200, trip ? { trip_headsign: `cíl ${trip[1]}` } : { n: calls.length });
    };
    const memory = new Map();
    const net = { token: 'x', demo: null, cache: memory };
    const limitedOnce = golemio.invokeApi(net, '/v2/limited/once');
    const limitedTwice = errorKind(() => golemio.invokeApi(net, '/v2/limited/twice'));

    await compareWithDesktop();
    const waste = await golemio.getWaste(demo, lat, lng);
    check('druhy podle nejbližšího svozu, papír jen jednou', waste.stations[0].kinds.map(kind => kind.type).join(', '), 'Plasty a nápojové kartony, Papír, Kovy, Barevné sklo');
    check('odjezdy a zastávky pro příští obnovení', await golemio.getTransit(demo, lat, lng, null).then(transit => `${transit.departures.length} ${transit.stops.length} ${transit.departures[1].in}`), '9 5 za 3 min');
    const details = (await golemio.getTransit(demo, lat, lng, null)).departures.map(departure => departure.detail.split('\n').slice(1).join(', '));
    check('podrobnosti spoje: zpoždění, poloha a vůz', details[1], 'Zpoždění 2 min, Naposledy v zastávce Jana Masaryka, Bezbariérový spoj, S klimatizací');
    check('podrobnosti: co API neví, se vynechá', details[3], 'Zpoždění není známé, Bezbariérový spoj');
    check('bez voleb platí výchozí, s volbou volba', `${golemio.getOption(demo, 'stopsRange')} ${golemio.getOption({ options: { stopsRange: 300 } }, 'stopsRange')}`, '600 300');

    console.log('--- otevírací doba');
    // 5. 10. 2026 je pondělí.
    const at = (day, hour, minute) => new Date(Date.UTC(2026, 9, day, hour - 2, minute));
    const office = [
        { day_of_week: 'Monday', opens: '08:00', closes: '12:00' },
        { day_of_week: 'Monday', opens: '13:00', closes: '17:30' },
        { day_of_week: 'Wednesday', opens: '08:00', closes: '12:00' },
    ];
    const open = golemio.getOpenStatus(office, at(5, 10, 30));
    check('otevřeno', `${open.text} ${open.open}`, 'otevřeno do 12:00 true');
    check('polední pauza', golemio.getOpenStatus(office, at(5, 12, 0)).text, 'otevírá v 13:00');
    check('večer: další úřední den je středa', golemio.getOpenStatus(office, at(5, 18, 0)).text, 'otevírá st v 8:00');
    check('den předem', golemio.getOpenStatus(office, at(6, 9, 0)).text, 'otevírá zítra v 8:00');
    check('bez otevírací doby a s nečitelnou nic', `${golemio.getOpenStatus(null, at(5, 10, 0))} ${golemio.getOpenStatus([{ day_of_week: 'Monday', opens: 'dle domluvy', closes: '' }], at(5, 10, 0))}`, 'null null');
    check('do půlnoci', golemio.getOpenStatus([{ day_of_week: 'Monday', opens: '18:00', closes: '00:00' }], at(5, 23, 30)).text, 'otevřeno do 24:00');
    const library = [
        { day_of_week: 'Monday', opens: '00:00', closes: '23:59', type: 'self_service', is_default: true },
        { day_of_week: 'Monday', opens: '13:00', closes: '19:00', type: 'standard', is_default: true },
    ];
    check('samoobsluha se nepočítá', golemio.getOpenStatus(library, at(5, 10, 0)).text, 'otevírá v 13:00');
    const holiday = [...library, {
        day_of_week: 'Monday', opens: '09:00', closes: '11:00', type: 'standard', is_default: false,
        valid_from: '2026-10-04T22:00:00.000Z', valid_through: '2026-10-11T21:59:59.000Z',
    }];
    check('mimořádná doba má přednost', golemio.getOpenStatus(holiday, at(5, 10, 0)).text, 'otevřeno do 11:00');
    check('po skončení platnosti zase běžná', golemio.getOpenStatus(holiday, at(12, 14, 0)).text, 'otevřeno do 19:00');

    console.log('--- limit API');
    let queue = Array(17).fill(Date.now());
    let started = Date.now();
    await golemio.waitRateLimit(queue);
    check('pod limitem se nečeká a dotaz se zapíše', `${Date.now() - started < 200} ${queue.length}`, 'true 18');
    queue = [Date.now() - 7600, ...Array(17).fill(Date.now())];
    started = Date.now();
    await golemio.waitRateLimit(queue);
    check('plné okno počká, až nejstarší dotaz vypadne', `${Date.now() - started >= 250 && Date.now() - started < 3000} ${queue.length}`, 'true 18');
    await golemio.waitRateLimit(null);

    console.log('--- paměť odpovědí');
    // Zestárne všechno, co v paměti je, o daný počet sekund.
    const age = seconds => { for (const entry of memory.values()) entry.at -= seconds * 1000; };
    calls = [];
    memory.clear();
    await golemio.invokeApi(net, '/v2/x', { a: 1 });
    const again = await golemio.invokeApi(net, '/v2/x', { a: 1 });
    check('stejný dotaz podruhé jde z paměti', `${calls.length} ${again.n}`, '1 1');
    await golemio.invokeApi(net, '/v2/x', { a: 2 });
    check('jiný dotaz jde na síť', calls.length, 2);
    age(599);
    await golemio.invokeApi(net, '/v2/x', { a: 1 });
    check('těsně před deseti minutami pořád z paměti', calls.length, 2);
    age(2);
    const fresh = await golemio.invokeApi(net, '/v2/x', { a: 1 });
    check('po deseti minutách znovu na síť', `${calls.length} ${fresh.n}`, '3 3');
    check('prošlé odpovědi se uklízejí', memory.size, 1);
    await golemio.invokeApi(net, '/v2/live', {}, golemio.cacheLive);
    await golemio.invokeApi(net, '/v2/live', {}, golemio.cacheLive);
    check('odjezdy hned podruhé z paměti', calls.length, 4);
    age(golemio.cacheLive + 1);
    await golemio.invokeApi(net, '/v2/live', {}, golemio.cacheLive);
    check('odjezdy po pár sekundách znovu na síť', calls.length, 5);
    await golemio.getCached(net, '/v2/dictionary');
    age(86400);
    await golemio.getCached(net, '/v2/dictionary');
    check('číselník se stahuje jednou', calls.length, 6);
    await golemio.testToken(net);
    await golemio.testToken(net);
    check('ověření klíče jde na síť pokaždé', calls.length, 8);
    const bare = { token: 'x', demo: null };
    await golemio.invokeApi(bare, '/v2/x');
    await golemio.invokeApi(bare, '/v2/x');
    check('bez paměti v kontextu se nepamatuje nic', calls.length, 10);

    // Nepovinné dotazy (kam jede vozidlo) nechávají v okně limitu místo těm, bez kterých karta není.
    const limited = { token: 'x', demo: null, cache: new Map(), limiter: Array(12).fill(Date.now()) };
    let before = calls.length;
    check('nepovinný dotaz se při plnějším okně neodešle', `${await errorKind(() => golemio.invokeApi(limited, '/v2/extra', {}, golemio.cacheSlow, true))} ${calls.length - before}`, 'Busy 0');
    await golemio.invokeApi(limited, '/v2/needed');
    check('povinný dotaz projde', `${calls.length - before} ${limited.limiter.length}`, '1 13');
    let moving = await golemio.getVehicles(limited, lat, lng);
    check('vozidla zatím bez cíle a s příznakem, že něco chybí', `${moving.pending} ${moving.items.filter(item => item.headsign).length} ${calls.length - before}`, 'true 0 2');
    limited.limiter.length = 0;
    moving = await golemio.getVehicles(limited, lat, lng);
    check('cíle se doplní, polohy se znovu nestahují', `${moving.pending} ${moving.items[0].headsign} ${calls.length - before}`, 'false cíl 991_11452_260202 6');
    await golemio.getVehicles(limited, lat, lng);
    check('potřetí už bez jediného dotazu', calls.length - before, 6);

    // Sada, ke které klíč nesmí: pamatuje se i odmítnutí, jinak by se na ni aplikace ptala při každém obnovení.
    before = calls.length;
    check('bez přístupu', `${await errorKind(() => golemio.invokeApi(net, '/v2/forbidden'))} ${await errorKind(() => golemio.invokeApi(net, '/v2/forbidden'))} ${calls.length - before}`, 'Forbidden Forbidden 1');
    age(golemio.cacheSlow + 1);
    check('po deseti minutách se zeptá znovu', `${await errorKind(() => golemio.invokeApi(net, '/v2/forbidden'))} ${calls.length - before}`, 'Forbidden 2');

    // Odmítnutí kvůli limitu (429): po okně limitu druhý pokus, teprve pak chyba.
    check('odmítnuto kvůli limitu: druhý pokus projde', typeof (await limitedOnce).n, 'number');
    check('dvakrát odmítnuto je chyba', await limitedTwice, 'RateLimited');

    console.log('--- místa, kde si specifikace API protiřečí');
    const withFiles = patches => ({ token: '', demo: readFrom(patches) });
    const history = 'v2-airqualitystations-history.json';
    const asNumber = text => text.replace('"AQ_hourly_index": "2A"', '"AQ_hourly_index": 3');
    check('index jako číslo', (await golemio.getAir(withFiles({ [history]: asNumber }), lat, lng)).index, 'Přijatelná');
    check('neznámý index', (await golemio.getAir(withFiles({ [history]: text => asNumber(text).replace('"AQ_hourly_index": 3', '"AQ_hourly_index": "9Z"') }), lat, lng)).index, 'Index 9Z');
    check('staré měření ovzduší', (await golemio.getAir(withFiles({ [history]: null }), lat, lng)).empty, 'Golemio má poslední měření ovzduší z 12. 8. v 8:45. Novější teď neposkytuje.');
    const listed = await golemio.getAir(withFiles({ [history]: null, 'v2-airqualitystations.json': text => text.replace('2026-08-12T06:45:00.621Z', '{{now-25}}') }), lat, lng);
    check('bez historie: čerstvý stav ze seznamu', `${listed.index} ${listed.components[0].value}`, 'Zhoršená až špatná 77,7 µg/m³');
    const onePoint = { 'v2-microclimate-points.json': () => '{"point_id": 207, "location_id": 200, "point_name": "Jediný bod", "lat": 50.0779, "lng": 14.45, "measures": []}' };
    const single = await golemio.getWeather(withFiles(onePoint), lat, lng);
    check('jeden bod místo seznamu', /^Jediný bod · \d+ m$/.test(single.meta), true);
    check('bez číselníku veličin zůstane kód', single.values.find(value => value.name === 'uv_index').value, '2');
    // Když senzory mlčí (naživo od dubna 2026), zbývá teplota od cyklosčítače. Nejbližší sčítač teploměr nemá, vezme se až další.
    const silent = { 'v2-microclimate-measurements.json': () => '[]' };
    const counter = await golemio.getWeather(withFiles(silent), lat, lng);
    check('senzory mlčí: teploměr u cyklosčítače', `${counter.meta} | ${counter.values.map(value => `${value.name} ${value.value}`)} | ${/^měřeno v \d{1,2}:\d\d$/.test(counter.updated)}`,
        'cyklosčítač Podolské nábřeží · 2,5 km | Teplota 14 °C | true');
    check('senzory selžou: teplota zůstane', (await golemio.getWeather(withFiles({ 'v2-microclimate-points.json': null }), lat, lng)).values[0].value, '14 °C');
    const stale = { ...silent, 'v2-bicyclecounters-temperatures.json': () => '[{"id": "camea-BC_PN-VYBR", "value": 9, "measured_to": "{{now-90}}"}]' };
    check('stará teplota se neukáže', (await golemio.getWeather(withFiles(stale), lat, lng)).empty, 'Golemio teď z okolí nemá čerstvé měření ze senzoru mikroklimatu ani z teploměru u cyklosčítače.');
    const noTrip = (await golemio.getVehicles(withFiles({ 'v2-public-gtfs-trips-22_1840_260901.json': null }), lat, lng)).items.find(item => item.route === '22');
    check('vozidlo bez popisu spoje', `${noTrip.headsign}|${noTrip.state}`, '|směr Z');
    // Klíč bez přístupu k velkoobjemovým kontejnerům: část se schová, není to chyba.
    globalThis.fetch = async uri => uri.includes('/bulky-waste/')
        ? { ok: false, status: 403, text: async () => '{}' }
        : { ok: true, status: 200, text: async () => JSON.stringify(await golemio.invokeApi(demo, new URL(uri).pathname)) };
    const noBulky = await golemio.getWaste({ token: 'x', demo: null }, lat, lng);
    check('bez přístupu k velkoobjemovým: zbytek karty zůstane', `${noBulky.showBulky} ${noBulky.bulkyNote}| ${noBulky.stations.length}`, 'false | 2');

    console.log('--- nastavení');
    const found = await golemio.findAddress(demo, 'náměstí Míru');
    check('krátká jména do pole s adresou', found.map(result => result.label).join(' | '), 'Náměstí Míru, Vinohrady | náměstí Míru, Zbraslav | náměstí Míru 8/2, Mělník');
    check('první adresa', `${found[0].name.split(',')[0]} ${found[0].latitude} ${found[0].longitude}`, 'Náměstí Míru 50.0753 14.4379');
    check('dům: ulice s číslem místo čísla na začátku', golemio.formatPlace({ display_name: '586/2, Korunní, Vinohrady, Praha', address: { road: 'Korunní', house_number: '586/2', suburb: 'Vinohrady' } }), 'Korunní 586/2, Vinohrady');
    check('ulice bez čísla: začátek celého jména', golemio.formatPlace({ display_name: 'Korunní, Vinohrady, Praha 2, Česko', address: { road: 'Korunní' } }), 'Korunní, Vinohrady');
    check('místo se jménem čtvrti se neopakuje', golemio.formatPlace({ name: 'Vinohrady', display_name: 'Vinohrady, Praha', address: { suburb: 'Vinohrady', city: 'Praha' } }), 'Vinohrady, Praha');
    check('ověření klíče', await golemio.testToken(demo), true);

    console.log(fail ? `\n${fail} chyb` : '\nVšechno prošlo.');
    process.exit(fail);
}

main();
