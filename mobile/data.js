// Datová vrstva mobilního Službáka: přepis Golemio.ps1 do JavaScriptu, funkce se jmenují stejně. O stránce nic neví,
// takže ji tests/mobile.js zkouší v Node i bez ní.
// Funkce get* vracejí objekty připravené k zobrazení, texty už jsou naformátované.
//
// context = { token, demo, limiter, cache, options }
// S demo (funkce, která vrátí text ukázkového souboru) se místo sítě čtou soubory ze složky demo (viz readDemo).
// limiter je seznam časů odeslaných dotazů (viz waitRateLimit), cache společná paměť odpovědí (Map, viz invokeApi),
// options volby uživatele (viz defaultOptions).
'use strict';

// Volby, které si uživatel může změnit v nastavení. Co v context.options chybí, platí odsud.
const defaultOptions = {
    stopsRange: 600,      // m, odkud se berou zastávky
    wasteRange: 400,      // m, stanoviště tříděného odpadu
    parkingRange: 1500,   // m, parkoviště
    departures: 12,       // kolik odjezdů ukázat
    refresh: 30,          // s, jak často stránka obnovuje odjezdy
};

function getOption(context, name) {
    return context.options?.[name] ?? defaultOptions[name];
}

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

// Co v PowerShellu dělá @(): nic = prázdný seznam, jedna hodnota = seznam o jedné položce.
function list(value) {
    return value == null ? [] : [].concat(value);
}

// Zaokrouhlení jako v .NET: půlky k sudému číslu. Bez toho by se telefon s počítačem občas rozešel o jedničku.
function round(value) {
    const rounded = Math.round(value);
    return Math.abs(value % 1) === 0.5 && rounded % 2 ? rounded - 1 : rounded;
}

const byDistance = (a, b) => a.distance - b.distance;

// ---- Chyby ----
// Chyba nese druh (Unauthorized, Forbidden, NotFound, RateLimited, Network, Unexpected) a českou hlášku pro uživatele.
// Druh Busy ven z datové vrstvy nejde: znamená odložený nepovinný dotaz (viz invokeApi).

function newApiError(kind, message) {
    const error = new Error(message);
    error.kind = kind;
    return error;
}

function convertToApiError(status) {
    switch (status) {
        case 401: return newApiError('Unauthorized', 'Golemio tenhle klíč odmítlo. Zkontroluj ho v nastavení.');
        case 403: return newApiError('Forbidden', 'Tvůj klíč k těmhle datům nemá přístup.');
        case 404: return newApiError('NotFound', 'Golemio tahle data nenašlo.');
        case 429: return newApiError('RateLimited', 'Příliš mnoho dotazů najednou, zkus to za chvíli.');
        default: return newApiError('Unexpected', `Golemio vrátilo chybu ${status}.`);
    }
}

// ---- HTTP a JSON ----

// encodeURIComponent nechává pár znaků, které .NET kóduje; adresa dotazu má být na telefonu i počítači stejná.
function escapeData(text) {
    return encodeURIComponent(text).replace(/[!'()*]/g, char => `%${char.charCodeAt(0).toString(16).toUpperCase()}`);
}

// Hodnota null se vynechá, pole zopakuje klíč (ids[]=a&ids[]=b).
function formatQuery(query) {
    const pairs = [];
    for (const [key, values] of Object.entries(query)) {
        for (const value of list(values)) pairs.push(`${escapeData(key)}=${escapeData(String(value))}`);
    }
    return pairs.length ? `?${pairs.join('&')}` : '';
}

function formatLatLng(latitude, longitude) {
    return `${Number(latitude.toFixed(6))},${Number(longitude.toFixed(6))}`;
}

async function invokeHttp(uri, token, service) {
    // Druhý pokus spraví spojení, které server mezitím zavřel, i chvilkový výpadek. Čte se jen (GET), takže neuškodí.
    // Pomáhá i u dotazů, na které Golemio poprvé odpovídá přes půl minuty: napodruhé už bývá odpověď hned.
    let response, text;
    for (const attempt of [1, 2]) {
        try {
            response = await fetch(uri, {
                headers: token ? { 'X-Access-Token': token.trim() } : {},
                // Odpovědi si prohlížeč nemá ukládat na disk: data se jen stahují a zobrazují.
                cache: 'no-store',
                signal: AbortSignal.timeout(30000),
            });
            text = await response.text();
            break;
        }
        catch (error) {
            if (attempt === 1) { await sleep(400); continue; }
            if (error.name === 'TimeoutError') throw newApiError('Network', `Služba ${service} neodpověděla včas. Zkus to za chvíli.`);
            throw newApiError('Network', `Nepodařilo se spojit se službou ${service}. Zkontroluj připojení k internetu.`);
        }
    }
    if (!response.ok) throw convertToApiError(response.status);

    try { return JSON.parse(text); }
    catch { throw newApiError('Unexpected', `Služba ${service} poslala odpověď, které nerozumím.`); }
}

// Ukázková data: /v2/pid/departureboards -> v2-pid-departureboards.json.
// {{now+5}} se nahradí časem za 5 minut, {{day+1}} zítřejším datem, aby ukázka nikdy nezestárla.
async function readDemo(read, name) {
    const text = await read(`${name.replace(/^\/+|\/+$/g, '').replaceAll('/', '-')}.json`);
    if (text == null) throw newApiError('NotFound', `Ukázková data pro ${name} chybí.`);

    // Půl minuty navíc, aby z {{now+5}} bylo po zaokrouhlení dolů pořád "za 5 min".
    const now = Date.now() + 30000;
    const day = getPragueDay(new Date(now)).getTime();
    return JSON.parse(text
        .replace(/\{\{now([+-]\d+)\}\}/g, (match, minutes) => formatPrague(new Date(now + Number(minutes) * 60000)))
        .replace(/\{\{day([+-]\d+)\}\}/g, (match, days) => new Date(day + Number(days) * 86400000).toISOString().slice(0, 10)));
}

// Golemio dovolí 20 dotazů za 8 sekund na jeden klíč; dva si necháváme v rezervě.
const rateLimit = 18;
const rateWindow = 8;
// Dotazy, bez kterých se karta obejde (kam jede vozidlo), nechávají tolik míst v okně volných pro ty podstatné.
const rateReserve = 6;

// Z fronty vypadnou dotazy starší než okno limitu; vrací, kolik jich v okně zbývá.
function getRateCount(limiter, now) {
    while (limiter.length && now - limiter[0] >= rateWindow * 1000) limiter.shift();
    return limiter.length;
}

// Sekce se načítají souběžně, takže si časy odeslaných dotazů hlídají ve společné frontě (context.limiter, pole).
// Když je okno plné, počká se, až nejstarší dotaz vypadne.
async function waitRateLimit(limiter) {
    if (!limiter) return;
    for (;;) {
        const now = Date.now();
        if (getRateCount(limiter, now) < rateLimit) {
            limiter.push(now);
            return;
        }
        await sleep(Math.max(50, rateWindow * 1000 - (now - limiter[0])));
    }
}

// Je v okně limitu místo i na dotaz, bez kterého se karta obejde? Kdyby takové dotazy okno zaplnily,
// čekaly by za nimi odjezdy.
function testRateRoom(limiter) {
    return !limiter || getRateCount(limiter, Date.now()) < rateLimit - rateReserve;
}

// ---- Paměť odpovědí ----
// Jak dlouho (v sekundách) se smí odpověď použít znovu, než se pro ni jde na síť. Šetří to API i limit dotazů:
// ruční obnovení, uložení nastavení ani rozbalení karty nestahují nic, co je ještě čerstvé.
const cacheSlow = 600;          // měření, svozy, obsazenost, místa: nejvýš jeden dotaz za 10 minut
const cacheLive = 10;           // odjezdy a polohy vozidel; jen brzda proti opakovanému obnovení
const cacheStatic = Infinity;   // číselníky, popisy spojů a zastávky kolem místa se za běhu nemění

// Paměť je Map v context.cache, kterou stránka dává všem dotazům společnou. Bez ní se nepamatuje nic
// (testy, ověření klíče). Je jen v paměti stránky: nikam se neukládá a se zavřením aplikace zmizí.
function getCacheEntry(context, key, maxAge) {
    if (!context.cache || maxAge <= 0) return null;
    // Stejná stránka umí ukázková i skutečná data, proto je v klíči i to, odkud jsou.
    const entry = context.cache.get(`${context.demo ? 'demo' : ''}|${key}`);
    return entry && (Date.now() - entry.at) / 1000 < maxAge ? entry : null;
}

function setCacheEntry(context, key, data, maxAge) {
    const cache = context.cache;
    if (!cache || maxAge <= 0) return;
    const now = Date.now();
    // Úklid prošlého: dotazy s časem v adrese mají každou hodinu jiný klíč a staré by tu zůstávaly ležet.
    for (const [old, entry] of cache) {
        if ((now - entry.at) / 1000 >= entry.maxAge) cache.delete(old);
    }
    // Popisy spojů neprojdou nikdy a přibývají celý den; občasné vymazání udrží paměť malou.
    if (cache.size >= 500) cache.clear();
    cache.set(`${context.demo ? 'demo' : ''}|${key}`, { at: now, maxAge, data });
}

// maxAge říká, jak starou odpověď z paměti lze ještě použít; 0 = pokaždé na síť (ověření klíče).
// S optional se dotaz při zaplněném limitu vůbec neodešle a skončí chybou druhu Busy: volající se bez
// odpovědi obejde a zkusí to později.
async function invokeApi(context, path, query = {}, maxAge = cacheSlow, optional = false) {
    const key = path + formatQuery(query);
    const hit = getCacheEntry(context, key, maxAge);
    if (hit) {
        if (hit.data instanceof Error) throw hit.data;
        return hit.data;
    }

    let data;
    if (context.demo) data = await readDemo(context.demo, path);
    else {
        if (optional && !testRateRoom(context.limiter)) throw newApiError('Busy', 'Na tenhle dotaz teď není v limitu místo.');
        const uri = `https://api.golemio.cz${key}`;
        await waitRateLimit(context.limiter);
        try { data = await invokeHttp(uri, context.token, 'Golemio'); }
        catch (error) {
            // Klíč, který k datové sadě nesmí, se sám nespraví. Pamatuje se i odmítnutí, ať se neptáme pořád dokola.
            if (error.kind === 'Forbidden') setCacheEntry(context, key, error, maxAge);
            if (error.kind !== 'RateLimited') throw error;
            // Limit platí na klíč, ne na telefon: vyčerpat ho mohl i Službák na počítači se stejným klíčem.
            // Po celém okně limitu se to zkusí ještě jednou; teprve pak je to chyba.
            await sleep(rateWindow * 1000);
            await waitRateLimit(context.limiter);
            data = await invokeHttp(uri, context.token, 'Golemio');
        }
    }
    setCacheEntry(context, key, data, maxAge);
    return data;
}

// Číselníky a popisy spojů se za běhu nemění; stačí je stáhnout jednou.
function getCached(context, path, query = {}, optional = false) {
    return invokeApi(context, path, query, cacheStatic, optional);
}

function formatUtc(time) {
    return `${time.toISOString().slice(0, 19)}Z`;
}

// Začátek hodiny před tolika hodinami. Čas v dotazu zaokrouhlený na celé hodiny drží adresu dotazu stejnou,
// takže se odpověď dá vzít z paměti; že je pak okno o necelou hodinu delší, ničemu nevadí.
function getHoursAgo(hours) {
    return new Date(Math.floor(Date.now() / 3600000 - hours) * 3600000);
}

// Světová strana, kam míří azimut ve stupních: 0 = S, 90 = V.
function formatCompass(bearing) {
    if (bearing == null || `${bearing}` === '') return '';
    return ['S', 'SV', 'V', 'JV', 'J', 'JZ', 'Z', 'SZ'][round(((Number(bearing) % 360) + 360) % 360 / 45) % 8];
}

// ---- Poloha a čas ----

function getDistance(latitude1, longitude1, latitude2, longitude2) {
    const rad = Math.PI / 180;
    const a = Math.sin((latitude2 - latitude1) * rad / 2) ** 2 +
        Math.cos(latitude1 * rad) * Math.cos(latitude2 * rad) * Math.sin((longitude2 - longitude1) * rad / 2) ** 2;
    return 2 * 6371000 * Math.asin(Math.sqrt(a));
}

function formatDistance(meters) {
    return meters < 995 ? `${round(meters / 10) * 10} m` : `${formatNumber(meters / 1000)} km`;
}

// "šířka,délka,šířka,délka" levého horního a pravého dolního rohu čtverce, jehož strany jsou radius metrů od středu.
function getBoundingBox(latitude, longitude, radius) {
    const dLat = radius / 6371000 * 180 / Math.PI;
    const dLng = dLat / Math.cos(latitude * Math.PI / 180);
    return `${formatLatLng(latitude + dLat, longitude - dLng)},${formatLatLng(latitude - dLat, longitude + dLng)}`;
}

// Pozice v GeoJSON je [délka, šířka]. U polygonu se vezme první vrchol, na umístění to stačí.
function readPosition(coordinates) {
    while (Array.isArray(coordinates) && Array.isArray(coordinates[0])) coordinates = coordinates[0];
    if (!Array.isArray(coordinates) || coordinates.length < 2) return null;
    const position = { latitude: Number(coordinates[1]), longitude: Number(coordinates[0]) };
    return Math.abs(position.latitude) <= 90 && Math.abs(position.longitude) <= 180 ? position : null;
}

// Prvky GeoJSON kolekce, které mají vlastnosti i polohu, se vzdáleností od zadaného bodu.
function getFeatures(collection, latitude, longitude) {
    const features = [];
    for (const feature of list(collection?.features)) {
        const position = feature?.properties && readPosition(feature.geometry?.coordinates);
        if (!position) continue;
        features.push({
            properties: feature.properties,
            position,
            distance: getDistance(latitude, longitude, position.latitude, position.longitude),
        });
    }
    return features;
}

// Data jsou o Praze, takže časy ukazujeme pražské, ať je telefon nastavený jakkoli. Okamžik je obyčejný Date;
// co ukazují pražské hodiny, z něj čtou až tyhle funkce.
const pragueClock = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Europe/Prague', hourCycle: 'h23',
    year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric',
});
const weekdays = ['ne', 'po', 'út', 'st', 'čt', 'pá', 'so'];
const two = number => String(number).padStart(2, '0');

// { year, month, day, hour, minute, second } na pražských hodinách.
function getPragueParts(time) {
    const parts = {};
    for (const part of pragueClock.formatToParts(time)) {
        if (part.type !== 'literal') parts[part.type] = Number(part.value);
    }
    return parts;
}

// Pražský den jako půlnoc UTC: dny se pak dají odčítat a porovnávat bez ohledu na letní čas.
function getPragueDay(time) {
    const parts = getPragueParts(time);
    return new Date(Date.UTC(parts.year, parts.month - 1, parts.day));
}

// O kolik milisekund je Praha před UTC.
function getPragueOffset(time) {
    const parts = getPragueParts(time);
    return Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second) - Math.floor(time / 1000) * 1000;
}

// "2026-10-07T08:16:30+02:00"
function formatPrague(time) {
    const parts = getPragueParts(time);
    const offset = getPragueOffset(time) / 60000;
    return `${parts.year}-${two(parts.month)}-${two(parts.day)}T${two(parts.hour)}:${two(parts.minute)}:${two(parts.second)}` +
        `${offset < 0 ? '-' : '+'}${two(Math.floor(Math.abs(offset) / 60))}:${two(Math.abs(offset) % 60)}`;
}

// Čas z API jako okamžik; nic, když to čas není. Bere jen zápis ISO, čas bez pásma je UTC.
function convertToPragueTime(text) {
    if (typeof text !== 'string' || !/^\d{4}-\d\d-\d\d/.test(text)) return null;
    const iso = text.trim().replace(' ', 'T');
    const zoned = iso.length === 10 || /(Z|[+-]\d\d(:?\d\d)?)$/i.test(iso.slice(10));
    const time = new Date(zoned ? iso : `${iso}Z`);
    return isNaN(time) ? null : time;
}

// Datum bez času: "2026-10-07" nebo celý časový údaj.
function convertToDay(text) {
    if (typeof text === 'string' && /^\d{4}-\d\d-\d\d$/.test(text)) {
        const day = new Date(`${text}T00:00:00Z`);
        return isNaN(day) ? null : day;
    }
    const time = convertToPragueTime(text);
    return time && getPragueDay(time);
}

// "dnes", "zítra", "st 7. 10."
function formatDay(day) {
    switch ((day - getPragueDay(new Date())) / 86400000) {
        case 0: return 'dnes';
        case 1: return 'zítra';
        default: return `${weekdays[day.getUTCDay()]} ${day.getUTCDate()}. ${day.getUTCMonth() + 1}.`;
    }
}

function formatClock(time) {
    const parts = getPragueParts(time);
    return `${parts.hour}:${two(parts.minute)}`;
}

// format: '0.#' nejvýš jedno desetinné místo, '0' celé číslo, '#,0' celé číslo s oddělenými tisíci.
function formatNumber(value, format = '0.#') {
    const scale = format === '0.#' ? 10 : 1;
    const rounded = Math.round(Math.abs(Number(value)) * scale) / scale;
    let text = String(rounded).replace('.', ',');
    if (format === '#,0') text = text.replace(/\B(?=(\d{3})+$)/g, '\xa0');
    return (value < 0 && rounded ? '-' : '') + text;
}

function convertToInt(value) {
    return value == null || `${value}` === '' ? null : round(Number(value));
}

// ---- Svoz odpadu ----

// Barvy podle druhu odpadu (id z API) jsou ty, které mají kontejnery v Česku: barevné sklo zelená,
// elektro červená, kovy šedá, nápojové kartony oranžová, papír modrá, plasty žlutá, čiré sklo bílá.
// Na jedlé oleje má Praha černou nádobu s fialovým víkem. Směsný odpad (černá) v téhle datové sadě není.
const wasteColors = {
    1: '#3FA34D', 2: '#E5484D', 3: '#A3A9B8', 4: '#F2994A', 5: '#3B82F6',
    6: '#F5C542', 7: '#E8EAF0', 8: '#B48EF2', 9: '#F5C542',
};
// "Multikomoditní sběr" (9) zní jako směsný odpad, ale je to žlutý kontejner: do něj se v Praze od roku 2024
// hází plasty spolu s nápojovými kartony. API tomu jinak neřekne, tak se to tady přejmenuje.
const wasteNames = { 9: 'Plasty a nápojové kartony' };

async function getWaste(context, latitude, longitude) {
    const range = getOption(context, 'wasteRange');
    const stations = await invokeApi(context, '/v2/sortedwastestations', {
        latlng: formatLatLng(latitude, longitude), range, limit: 3,
    });

    const today = getPragueDay(new Date());
    const nests = getFeatures(stations, latitude, longitude).filter(nest => nest.distance <= range).sort(byDistance).slice(0, 3).map(nest => {
        const station = nest.properties;
        // Stanoviště mívá víc kontejnerů téhož druhu; pro přehled stačí jeden řádek na druh.
        const groups = Map.groupBy(list(station.containers).filter(Boolean), container => String(container.trash_type?.id ?? ''));
        const kinds = [...groups.values()].map(group => {
            const first = group[0];
            const next = group.map(container => convertToDay(container.cleaning_frequency?.next_pick))
                .filter(day => day && day >= today).sort((a, b) => a - b)[0];
            const fill = group.map(container => convertToInt(container.last_measurement?.percent_calculated))
                .filter(percent => percent != null).sort((a, b) => b - a)[0];
            const kind = convertToInt(first.trash_type?.id) ?? 0;
            return {
                type: wasteNames[kind] || String(first.trash_type?.description || 'Odpad'),
                color: wasteColors[kind] ?? '#8C93A8',
                pickDays: String(first.cleaning_frequency?.pick_days ?? ''),
                day: next ? next.getTime() : Infinity,
                next: next ? formatDay(next) : '',
                fill: fill != null ? `${fill} %` : '',
            };
        // Nahoře to, co se sveze nejdřív; druhy bez termínu až na konci.
        }).sort((a, b) => a.day - b.day || a.type.localeCompare(b.type, 'cs'));

        return {
            name: station.name ? String(station.name) : 'Stanoviště',
            distance: formatDistance(nest.distance),
            access: String(station.accessibility?.description ?? ''),
            kinds,
        };
    });

    // Velkoobjemové kontejnery jsou navíc; když selžou, tříděný odpad se ukáže i tak.
    let bulky = [];
    let bulkyError = '';
    let bulkyAllowed = true;
    try {
        // Jako jediný bere tenhle endpoint vzdálenost v kilometrech.
        const containers = await invokeApi(context, '/v1/bulky-waste/stations', { latlng: formatLatLng(latitude, longitude), range: 2 });
        bulky = getFeatures(containers, latitude, longitude).filter(container => container.distance <= 1500).map(container => {
            const day = convertToDay(container.properties.date);
            if (!day || day < today) return null;
            const hours = [container.properties.timeFrom, container.properties.timeTo].filter(Boolean)
                .map(time => String(time).replace(/^0?(\d+):(\d\d).*$/, '$1:$2')).join('–');
            return {
                day: day.getTime(),
                meters: container.distance,
                when: [formatDay(day), hours].filter(Boolean).join(' · '),
                street: String(container.properties.street ?? ''),
                distance: formatDistance(container.distance),
            };
        }).filter(Boolean).sort((a, b) => a.day - b.day || a.meters - b.meters).slice(0, 4);
    }
    catch (error) {
        // Běžný klíč k téhle sadě přístup mít nemusí. To není porucha, část se prostě neukáže.
        if (error.kind === 'Forbidden') bulkyAllowed = false;
        else bulkyError = error.message;
    }

    return {
        meta: nests.length ? `${nests.length} nejbližší` : '',
        stations: nests,
        showBulky: bulkyAllowed,
        bulky,
        bulkyNote: bulkyError || (bulkyAllowed && !bulky.length ? 'V okolí teď žádný není v plánu.' : ''),
        empty: nests.length ? '' : `Do ${formatDistance(range)} žádné stanoviště tříděného odpadu není.`,
    };
}

// ---- Ovzduší ----

function formatFormula(code) {
    // NO2 -> NO₂, PM2_5 -> PM2,5
    if (/^PM/i.test(code)) return code.replaceAll('_', ',');
    return code.replaceAll('2', '₂').replaceAll('3', '₃');
}

// Index ovzduší je hodinový; starší měření už o vzduchu venku nic neříká.
const airFreshHours = 6;

async function getAir(context, latitude, longitude) {
    const stations = await invokeApi(context, '/v2/airqualitystations', { latlng: formatLatLng(latitude, longitude), limit: 10 });
    const nearest = getFeatures(stations, latitude, longitude).sort(byDistance);
    if (!nearest.length) return { meta: '', empty: 'Golemio nevrátilo žádnou měřicí stanici.' };

    // Seznam stanic nese poslední stav, který k němu Golemio dostalo, a ten bývá i měsíce starý. Čerstvá měření
    // jsou v historii: jeden dotaz na všechny stanice, ať se nemusí zkoušet jedna po druhé.
    const newest = new Map();
    try {
        const history = await invokeApi(context, '/v2/airqualitystations/history', { from: formatUtc(getHoursAgo(airFreshHours)) });
        for (const row of list(history)) {
            const time = convertToPragueTime(row?.updated_at);
            const id = String(row?.id ?? '');
            if (time && id && !(newest.get(id)?.time >= time)) newest.set(id, { time, measurement: row.measurement });
        }
    }
    catch { }

    const now = new Date();
    const readings = [];
    for (const candidate of nearest) {
        const reading = newest.get(String(candidate.properties.id)) ??
            { time: convertToPragueTime(candidate.properties.updated_at), measurement: candidate.properties.measurement };
        // Stanice, která zrovna nic neměří, se přeskočí; vezme se nejbližší, která data má.
        if (list(reading.measurement?.components).some(component => component?.averaged_time?.value != null)) {
            readings.push({ station: candidate, time: reading.time, measurement: reading.measurement });
        }
    }
    if (!readings.length) return { meta: '', empty: 'Žádná stanice v okolí teď neměří.' };

    // Staré měření se jako aktuální ukázat nesmí. Chybí-li čas úplně, nedá se stáří posoudit a měření se ukáže.
    const reading = readings.find(candidate => !candidate.time || (now - candidate.time) / 3600000 <= airFreshHours);
    if (!reading) {
        const last = readings.map(candidate => candidate.time).sort((a, b) => b - a)[0];
        const day = getPragueDay(last);
        return {
            meta: '',
            empty: `Golemio má poslední měření ovzduší z ${day.getUTCDate()}. ${day.getUTCMonth() + 1}. v ${formatClock(last)}. Novější teď neposkytuje.`,
        };
    }
    const station = reading.station;
    const measurement = reading.measurement;

    // Číselníky jsou jen na popisky a barvy; bez nich se ukážou holé kódy.
    let indexTypes = [];
    let componentTypes = [];
    try {
        indexTypes = list(await getCached(context, '/v2/airqualitystations/indextypes'));
        componentTypes = list(await getCached(context, '/v2/airqualitystations/componenttypes'));
    }
    catch { }

    // Specifikace uvádí index jako číslo, číselník má ale kódy typu "1A"; bereme obojí.
    const code = measurement.AQ_hourly_index != null ? String(measurement.AQ_hourly_index) : '';
    const index = indexTypes.find(type => code && (String(type.index_code) === code || String(type.id) === code));
    const description = String(index?.description_cs ?? '');

    const components = list(measurement.components).filter(component => component?.type && component.averaged_time?.value != null).map(component => {
        const type = componentTypes.find(candidate => candidate.component_code === component.type);
        const hours = convertToInt(component.averaged_time.averaged_hours) ?? 0;
        return {
            code: String(component.type),
            hours,
            name: formatFormula(String(component.type)),
            description: String(type?.description_cs ?? ''),
            value: [formatNumber(component.averaged_time.value), String(type?.unit ?? '')].filter(Boolean).join(' '),
            period: hours ? `průměr za ${hours} h` : '',
            // Totéž na jeden řádek karty.
            detail: [String(type?.description_cs ?? ''), hours ? `${hours} h` : ''].filter(Boolean).join(' · '),
        };
    }).sort((a, b) => a.code.localeCompare(b.code, 'cs') || a.hours - b.hours);

    const updated = reading.time;
    return {
        meta: `${station.properties.name} · ${formatDistance(station.distance)}`,
        index: description ? description[0].toLocaleUpperCase('cs') + description.slice(1) : code ? `Index ${code}` : 'Index není k dispozici',
        indexColor: index?.color ? `#${index.color}` : '#222838',
        indexTextColor: index?.color_text ? `#${index.color_text}` : '#ECEEF4',
        updated: updated ? `měřeno ${formatDay(getPragueDay(updated))} v ${formatClock(updated)}` : '',
        components,
        empty: '',
    };
}

// ---- Mikroklima ----

// Veličiny v pořadí, v jakém je karta ukazuje. Kód z API má za názvem výšku čidla v cm (air_temp200).
const microclimateMeasures = {
    air_temp: 'Teplota', air_hum: 'Vlhkost', pressure: 'Tlak', wind_speed: 'Vítr',
    wind_impact: 'Nárazy větru', wind_dir: 'Směr větru', precip: 'Srážky', sun_irr: 'Osvit',
};
// Senzory hlásí po deseti minutách; dvě hodiny zpět stačí a odpověď za všechny senzory zůstane malá.
const microclimateHours = 2;

function formatMeasure(base, value, unit) {
    if (base === 'wind_dir') return formatCompass(value);
    // Tlak chodí v pascalech, zvyk je v hektopascalech.
    if (unit === 'Pa') return `${formatNumber(Number(value) / 100, '0')} hPa`;
    return [formatNumber(value), unit].filter(Boolean).join(' ');
}

async function getMicroclimate(context, latitude, longitude) {
    // Specifikace tu popisuje jeden objekt, i když jde o seznam; list() srovná obojí.
    const points = list(await getCached(context, '/v2/microclimate/points'))
        .filter(point => point && point.lat != null && point.lng != null && point.point_id != null);
    if (!points.length) return { meta: '', empty: 'Golemio nevrátilo žádný senzor mikroklimatu.' };

    // Jeden dotaz na všechny senzory: nejbližší často mlčí a zkoušet je po jednom by stálo dotaz za každý.
    const rows = list(await invokeApi(context, '/v2/microclimate/measurements', { from: formatUtc(getHoursAgo(microclimateHours)) }))
        .filter(row => row?.measure && row.value != null);
    const measured = Map.groupBy(rows, row => String(row.point_id));
    const distanceTo = point => getDistance(latitude, longitude, Number(point.lat), Number(point.lng));
    const point = points.filter(candidate => measured.has(String(candidate.point_id))).sort((a, b) => distanceTo(a) - distanceTo(b))[0];
    if (!point) return { meta: '', empty: 'Golemio teď nemá čerstvá data z žádného senzoru mikroklimatu.' };

    let latest = null;
    const order = Object.keys(microclimateMeasures);
    const timeOf = row => convertToPragueTime(row.measured_at) ?? 0;
    // Stejná veličina z více výšek se ukáže jednou, z té vyšší (dva metry jsou běžná výška měření).
    const groups = Map.groupBy(measured.get(String(point.point_id)), row => String(row.measure).replace(/\d+$/, ''));
    const values = [...groups].map(([base, group]) => {
        const height = Math.max(...group.map(row => Number(/\d+$/.exec(String(row.measure))?.[0] ?? 0)));
        const last = group.filter(row => String(row.measure) === (height ? `${base}${height}` : base)).sort((a, b) => timeOf(b) - timeOf(a))[0];
        const time = convertToPragueTime(last.measured_at);
        if (time && !(latest >= time)) latest = time;
        const measure = list(point.measures).find(candidate => candidate?.measure === last.measure);
        return {
            // Vlastní krátké jméno, jinak české jméno z číselníku senzoru, jinak aspoň kód.
            name: [microclimateMeasures[base], measure?.measure_cz, String(last.measure)].find(Boolean),
            value: formatMeasure(base, last.value, String(last.unit ?? '')),
            order: order.includes(base) ? order.indexOf(base) : order.length,
        };
    }).sort((a, b) => a.order - b.order || a.name.localeCompare(b.name, 'cs'));

    // Bod se podle specifikace jmenuje point_named, naživo point_name.
    const name = [point.point_named, point.point_name, point.location].find(Boolean);
    return {
        meta: `${name} · ${formatDistance(distanceTo(point))}`,
        values,
        updated: latest ? `měřeno v ${formatClock(latest)}` : '',
        empty: '',
    };
}

// ---- Parkování ----

const parkingKinds = {
    park_and_ride: 'P+R', kiss_and_ride: 'K+R', commercial: 'Placené', customer_only: 'Pro zákazníky',
    park_sharing: 'Sdílené', zone: 'Zóna',
    underground: 'Podzemní', multi_storey: 'Parkovací dům', surface: 'Parkoviště', on_street: 'Na ulici', rooftop: 'Na střeše',
};

async function getParking(context, latitude, longitude) {
    const range = getOption(context, 'parkingRange');
    const parking = await invokeApi(context, '/v3/parking', {
        boundingBox: getBoundingBox(latitude, longitude, range),
        // Všechno kromě "zone": pouličních zón jsou v každém bloku desítky. "none" = parkování bez režimu.
        'parkingPolicy[]': ['commercial', 'customer_only', 'kiss_and_ride', 'park_and_ride', 'park_sharing', 'none'],
    });

    const places = list(parking?.features).map(feature => {
        if (!feature?.properties?.id) return null;
        // Geometrie bývá obrys parkoviště, proto má přednost těžiště.
        const position = readPosition(feature.properties.centroid?.coordinates) ?? readPosition(feature.geometry?.coordinates);
        return position && { properties: feature.properties, distance: getDistance(latitude, longitude, position.latitude, position.longitude) };
    // API vrací čtverec kolem místa; co je v jeho rozích dál než okruh, se zahodí.
    }).filter(place => place && place.distance <= range).sort(byDistance).slice(0, 6);
    if (!places.length) return { meta: '', empty: `Do ${formatDistance(range)} žádné parkoviště není.` };

    // Obsazenost je v samostatném endpointu a má ji jen část parkovišť.
    const occupancy = new Map();
    const ids = places.filter(place => place.properties.has_occupancy_info).map(place => String(place.properties.id));
    if (ids.length) {
        try {
            for (const row of list(await invokeApi(context, '/v3/parking-measurements', { 'parkingId[]': ids }))) {
                if (row?.parking_id) occupancy.set(String(row.parking_id), row);
            }
        }
        catch { }
    }

    // Parkovací automat je jen doplněk; když dotaz selže nebo žádný poblíž není, řádek se neukáže.
    let machine = '';
    try {
        const machines = await invokeApi(context, '/v3/parking-machines', { boundingBox: getBoundingBox(latitude, longitude, range), limit: 200 });
        const closest = getFeatures(machines, latitude, longitude).filter(candidate => candidate.distance <= range).sort(byDistance)[0];
        if (closest) machine = `Nejbližší parkovací automat ${formatDistance(closest.distance)}`;
    }
    catch { }

    return {
        meta: `do ${formatDistance(range)}`,
        machine,
        items: places.map(place => {
            const p = place.properties;
            const measured = occupancy.get(String(p.id));
            const capacity = convertToInt(measured?.total_spot_number ?? p.capacity);
            const free = measured ? convertToInt(measured.free_spot_number) : null;
            const kind = parkingKinds[p.parking_policy] ?? parkingKinds[p.parking_type] ?? '';
            return {
                name: [p.name, p.address?.address_formatted, 'Parkoviště'].find(Boolean),
                kind,
                distance: formatDistance(place.distance),
                // Vzdálenost první: když se řádek do karty nevejde celý, ořízne se konec.
                detail: [formatDistance(place.distance), kind].filter(Boolean).join(' · '),
                // Bez měření obsazenosti se místo volných míst ukáže aspoň kapacita (šedě, viz freeColor).
                free: free != null ? `${free}` : capacity ? `${capacity}` : '',
                capacity: free != null && capacity ? `volných z ${capacity}` : free != null ? 'volných' : capacity ? 'míst' : '',
                freeColor: free == null ? '#8C93A8' : free === 0 ? '#FF8A80' : '#7BD88F',
            };
        }),
        empty: '',
    };
}

// ---- MHD ----

// Typy linek podle GTFS a barvy, jak je používá PID.
const routeColors = { 0: '#7A0603', 1: '#5B6170', 2: '#251E62', 3: '#007DA8', 4: '#00B3CB', 7: '#7A0603', 11: '#80166F' };
const metroColors = { A: '#00A562', B: '#F8B322', C: '#CF003D', D: '#008BBE' };

// Najde nástupiště v okolí. Endpoint neumí filtr podle polohy, takže se přečte celý seznam po stránkách.
async function findStops(context, latitude, longitude) {
    const pageSize = 10000;
    const range = getOption(context, 'stopsRange');
    // Pamatuje se jen výsledek pro tohle místo a okruh. Stránky seznamu ne: mají desítky megabajtů.
    const key = `stops|${formatLatLng(latitude, longitude)}|${range}`;
    const hit = getCacheEntry(context, key, cacheStatic);
    if (hit) return hit.data;

    const near = [];
    for (let offset = 0; ; offset += pageSize) {
        const page = await invokeApi(context, '/v2/gtfs/stops', { limit: pageSize, offset }, 0);
        for (const stop of getFeatures(page, latitude, longitude)) {
            const p = stop.properties;
            // location_type 0 je nástupiště; stanice, vstupy a další uzly odjezdy nemají.
            if (stop.distance <= range && p.stop_id && !Number(p.location_type)) {
                near.push({
                    id: String(p.stop_id),
                    name: String(p.stop_name || p.stop_id),
                    platform: String(p.platform_code ?? ''),
                    meters: stop.distance,
                });
            }
        }
        if (list(page?.features).length < pageSize) break;
    }
    const found = near.sort((a, b) => a.meters - b.meters).slice(0, 10);
    setCacheEntry(context, key, found, cacheStatic);
    return found;
}

function getRouteColor(type, route) {
    if (type === 1 && metroColors[route]) return metroColors[route];
    return routeColors[type] ?? '#5B6170';
}

// Žlutá linka B potřebuje tmavé písmo, na ostatních barvách je čitelné bílé.
function getRouteTextColor(color) {
    return color === metroColors.B ? '#1F1405' : '#FFFFFF';
}

async function getTransit(context, latitude, longitude, stops) {
    stops ??= await findStops(context, latitude, longitude);
    if (!stops.length) {
        const range = formatDistance(getOption(context, 'stopsRange'));
        return { meta: '', stops, departures: [], infotexts: [], empty: `Do ${range} žádná zastávka PID není.` };
    }

    const count = getOption(context, 'departures');
    const board = await invokeApi(context, '/v2/pid/departureboards', {
        'ids[]': stops.map(stop => stop.id), minutesAfter: 90, limit: count,
    }, cacheLive);

    const names = new Map(stops.map(stop => [stop.id, stop]));
    const now = new Date();

    const departures = list(board?.departures).filter(Boolean).slice(0, count).map(departure => {
        const scheduled = convertToPragueTime(departure.departure_timestamp?.scheduled);
        const predicted = convertToPragueTime(departure.departure_timestamp?.predicted);
        const time = predicted ?? scheduled;
        if (!time) return null;

        const minutes = Math.floor((time - now) / 60000);
        const delay = departure.delay?.is_available && departure.delay.seconds != null ? round(Number(departure.delay.seconds) / 60) : 0;
        const stop = names.get(String(departure.stop?.id));
        const platform = [departure.stop?.platform_code, stop?.platform].find(Boolean);
        const route = String(departure.route?.short_name ?? '');
        const color = getRouteColor(convertToInt(departure.route?.type), route);
        const canceled = Boolean(departure.trip?.is_canceled);

        return {
            route,
            color,
            routeTextColor: getRouteTextColor(color),
            headsign: String(departure.trip?.headsign ?? ''),
            stop: [stop?.name || String(departure.stop?.id ?? ''), platform].filter(Boolean).join(' · '),
            in: canceled ? 'zrušeno' : departure.trip?.is_at_stop || minutes <= 0 ? 'teď' : `za ${minutes} min`,
            inColor: canceled ? '#FF8A80' : '#ECEEF4',
            time: formatClock(time),
            delay: delay >= 1 && !canceled ? `+${delay} min` : '',
            opacity: canceled ? 0.55 : 1,
        };
    }).filter(Boolean);

    const stopNames = [...new Set(stops.map(stop => stop.name))];
    return {
        meta: stopNames.slice(0, 3).join(', ') + (stopNames.length > 3 ? ' a další' : ''),
        stops,
        departures,
        infotexts: list(board?.infotexts).filter(infotext => infotext?.text).map(infotext => ({ text: String(infotext.text) })),
        empty: departures.length ? '' : 'V příští hodině a půl odsud nic nejede.',
    };
}

// ---- Vozidla MHD v okolí ----

// Druh dopravy tu chodí slovem; barvy jsou stejné jako u odjezdů (číselné typy GTFS).
const routeTypes = { tram: 0, metro: 1, train: 2, bus: 3, ferry: 4, funicular: 7, trolleybus: 11 };
const vehicleRange = 1000;

async function getVehicles(context, latitude, longitude) {
    const positions = await invokeApi(context, '/v2/public/vehiclepositions', { boundingBox: getBoundingBox(latitude, longitude, vehicleRange) }, cacheLive);
    const near = getFeatures(positions, latitude, longitude).filter(vehicle => vehicle.distance <= vehicleRange).sort(byDistance);
    if (!near.length) return { meta: '', empty: `Do ${formatDistance(vehicleRange)} teď žádný spoj MHD nejede.` };

    let pending = false;
    const items = await Promise.all(near.slice(0, 8).map(async vehicle => {
        const p = vehicle.properties;
        const route = String(p.gtfs_route_short_name ?? '');
        // Kam spoj jede, v polohách není. Dotáže se jednou na každý spoj a pak už se bere z paměti.
        // Je to dotaz navíc za každé vozidlo: když je limit skoro plný, cíl se doplní až příště.
        let headsign = '';
        if (p.gtfs_trip_id) {
            try { headsign = String((await getCached(context, `/v2/public/gtfs/trips/${p.gtfs_trip_id}`, { 'scopes[]': 'info' }, true))?.trip_headsign ?? ''); }
            catch (error) { if (error.kind === 'Busy') pending = true; }
        }
        const delay = p.delay != null ? round(Number(p.delay) / 60) : 0;
        const color = getRouteColor(routeTypes[p.route_type], route);
        const compass = formatCompass(p.bearing);
        return {
            route,
            color,
            routeTextColor: getRouteTextColor(color),
            headsign,
            state: p.state_position === 'at_stop' ? 'v zastávce' : compass && `směr ${compass}`,
            delay: delay >= 1 ? `+${delay} min` : '',
            distance: formatDistance(vehicle.distance),
        };
    }));

    return {
        meta: `${near.length} do ${formatDistance(vehicleRange)}`,
        items,
        // Něco se odložilo; stránka má sekci načíst znovu dřív než při běžném obnovení.
        pending,
        empty: '',
    };
}

// ---- Mimořádnosti PID ----

async function getAlerts(context, latitude, longitude) {
    const order = { high: 0, normal: 1, low: 2 };
    // Stejný text chodí zvlášť pro každou dotčenou zastávku; v kartě je jednou a zastávky se sečtou.
    const groups = Map.groupBy(list(await invokeApi(context, '/v3/pid/infotexts')).filter(infotext => infotext?.text), infotext => String(infotext.text));
    const all = [...groups].map(([text, group]) => ({
        text,
        rank: Math.min(...group.map(infotext => order[infotext.priority] ?? 1)),
        stops: [...new Set(group.flatMap(infotext => list(infotext.related_stops)).map(stop => String(stop?.name ?? '')).filter(Boolean))],
        until: group.map(infotext => convertToPragueTime(infotext.valid_to)).filter(Boolean).sort((a, b) => b - a)[0] ?? null,
    // Bez konce platnosti napřed; stejně naléhavé se stejným koncem podle abecedy, ať pořadí neskáče.
    })).sort((a, b) => a.rank - b.rank || (a.until ?? 0) - (b.until ?? 0) || a.text.localeCompare(b.text, 'cs'));
    if (!all.length) return { meta: '', empty: 'PID teď žádnou mimořádnost nehlásí.' };

    const shown = 4;
    const today = getPragueDay(new Date());
    return {
        meta: `${all.length} v celé síti`,
        items: all.slice(0, shown).map(alert => {
            const day = alert.until && getPragueDay(alert.until);
            return {
                text: alert.text,
                stops: alert.stops.slice(0, 3).join(', ') + (alert.stops.length > 3 ? ' a další' : ''),
                until: !day ? '' : day.getTime() === today.getTime() ? 'dnes končí' : `do ${formatDay(day)}`,
                color: alert.rank === 0 ? '#FF8A80' : '#E9A45B',
            };
        }),
        more: all.length > shown ? `a ${all.length - shown} další` : '',
        empty: '',
    };
}

// ---- Sdílená auta ----

const carRange = 1500;

async function getCars(context, latitude, longitude) {
    const cars = await invokeApi(context, '/v2/sharedcars', { latlng: formatLatLng(latitude, longitude), range: carRange, limit: 50 });
    const near = getFeatures(cars, latitude, longitude).filter(car => car.distance <= carRange).sort(byDistance);
    if (!near.length) return { meta: '', empty: `Do ${formatDistance(carRange)} teď žádné sdílené auto nestojí.` };

    return {
        meta: `${near.length} do ${formatDistance(carRange)}`,
        items: near.slice(0, 5).map(car => {
            const p = car.properties;
            return {
                // Značka bývá v názvu dvakrát ("Toyota Toyota Aygo X").
                name: String(p.name ?? '').replace(/^(\S+) \1 /i, '$1 '),
                detail: [p.company?.name, p.fuel?.description, p.availability?.description].filter(Boolean).join(' · '),
                distance: formatDistance(car.distance),
            };
        }),
        empty: '',
    };
}

// ---- Cyklosčítače ----

async function getCycling(context, latitude, longitude) {
    const counters = await invokeApi(context, '/v2/bicyclecounters', { latlng: formatLatLng(latitude, longitude), limit: 3 });
    const near = getFeatures(counters, latitude, longitude).sort(byDistance).slice(0, 3);
    if (!near.length) return { meta: '', empty: 'Golemio nevrátilo žádný cyklosčítač.' };

    // Součty od půlnoci za všechny směry nejbližších sčítačů jedním dotazem (je pomalý, i několik sekund).
    const now = new Date();
    const midnight = new Date(getPragueDay(now).getTime() - getPragueOffset(now));
    const ids = near.flatMap(counter => list(counter.properties.directions)).map(direction => String(direction?.id ?? '')).filter(Boolean);
    const sums = new Map();
    for (const row of list(await invokeApi(context, '/v2/bicyclecounters/detections', { 'id[]': ids, from: formatUtc(midnight), aggregate: true }))) {
        if (row?.id) sums.set(String(row.id), row);
    }

    const counted = near.map(counter => {
        const directions = list(counter.properties.directions).filter(direction => direction?.id).map(direction => {
            const sum = sums.get(String(direction.id));
            return { name: String(direction.name ?? ''), bikes: convertToInt(sum?.value) ?? 0, walkers: convertToInt(sum?.value_pedestrians) };
        });
        return { counter, directions, total: directions.reduce((total, direction) => total + direction.bikes, 0) };
    });
    // Sčítač, který nefunguje, hlásí celý den nulu; vezme se nejbližší, který dnes něco napočítal.
    const picked = counted.find(candidate => candidate.total > 0);
    if (!picked) return { meta: '', empty: 'Nejbližší cyklosčítače dnes zatím žádný průjezd nezapsaly.' };

    const p = picked.counter.properties;
    return {
        meta: `${p.name} · ${formatDistance(picked.counter.distance)}`,
        total: formatNumber(picked.total, '#,0'),
        caption: `kol od půlnoci${p.route ? ` · trasa ${p.route}` : ''}`,
        items: picked.directions.map(direction => ({
            name: `směr ${direction.name}`,
            value: formatNumber(direction.bikes, '#,0') + (direction.walkers ? ` · pěších ${formatNumber(direction.walkers, '#,0')}` : ''),
        })),
        empty: '',
    };
}

// ---- Městská část ----

// Leží bod uvnitř obrysu? Obrys je seznam vrcholů [délka, šířka]; počítá se, kolikrát ho protne polopřímka z bodu.
function testInRing(ring, latitude, longitude) {
    let inside = false;
    const points = list(ring);
    for (let i = 0; i < points.length; i++) {
        const [x1, y1] = points[i];
        const [x2, y2] = points[(i + 1) % points.length];
        if ((y1 > latitude) !== (y2 > latitude) && longitude < (x2 - x1) * (latitude - y1) / (y2 - y1) + x1) inside = !inside;
    }
    return inside;
}

// Jméno městské části, ve které místo leží; nic, když je mimo Prahu.
async function getDistrict(context, latitude, longitude) {
    const districts = await invokeApi(context, '/v2/citydistricts', { latlng: formatLatLng(latitude, longitude), limit: 4 }, cacheStatic);
    for (const feature of list(districts?.features)) {
        if (!feature?.geometry) continue;
        // Polygon má vnější obrys v coordinates[0], MultiPolygon má takových částí víc.
        const polygons = feature.geometry.type === 'MultiPolygon' ? feature.geometry.coordinates : [feature.geometry.coordinates];
        if (list(polygons).some(polygon => testInRing(polygon?.[0], latitude, longitude))) return String(feature.properties?.name ?? '');
    }
    return '';
}

// ---- V okolí ----

// Od každého druhu místa se ukáže to nejbližší. range je v metrech: sběrných dvorů je málo, lékáren hodně.
// group a types se navíc hlídají i tady, protože zdravotnická zařízení jsou v jedné sadě všechna dohromady.
// Zahrad je v celé Praze pár desítek, proto se hledají bez omezení vzdálenosti.
const nearbyKinds = [
    { label: 'Lékárna', path: '/v2/medicalinstitutions', group: 'pharmacies', range: 3000 },
    { label: 'Nemocnice', path: '/v2/medicalinstitutions', group: 'health_care', types: ['Nemocnice', 'Fakultní nemocnice'], range: 10000, limit: 300 },
    { label: 'Knihovna', path: '/v2/municipallibraries', range: 5000 },
    { label: 'Úřad', path: '/v2/municipalauthorities', range: 5000 },
    { label: 'Městská policie', path: '/v2/municipalpolicestations', range: 5000 },
    { label: 'Sběrný dvůr', path: '/v2/wastecollectionyards', range: 10000 },
    { label: 'Hřiště', path: '/v2/playgrounds', range: 5000 },
    { label: 'Zahrada', path: '/v2/gardens' },
];
const dayNames = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

// "09:00" -> 540 minut od půlnoci; nic, když to není čas.
function convertToMinutes(text) {
    const match = /^\s*(\d{1,2}):(\d\d)/.exec(`${text ?? ''}`);
    return match && Number(match[1]) * 60 + Number(match[2]);
}

function formatMinutes(minutes) {
    return `${Math.floor(minutes / 60)}:${two(minutes % 60)}`;
}

// Z otevírací doby (dny v týdnu anglicky, časy "HH:mm") udělá "otevřeno do 18:00", "otevírá v 9:00",
// "otevírá zítra v 8:00" nebo "otevírá po v 8:00". Vrací { text, open }, nebo nic, když doba chybí.
function getOpenStatus(hours, now) {
    let valid = list(hours).filter(entry => {
        if (!entry || convertToMinutes(entry.opens) == null || convertToMinutes(entry.closes) == null) return false;
        const from = convertToPragueTime(entry.valid_from);
        const through = convertToPragueTime(entry.valid_through);
        // Samoobslužný provoz knihoven (vracení knih do boxu) není otevřeno.
        return entry.type !== 'self_service' && (!from || from <= now) && (!through || through >= now);
    });
    if (!valid.length) return null;
    // Mimořádná doba (svátky, prázdniny) má po dobu své platnosti přednost před běžnou.
    const special = valid.filter(entry => 'is_default' in entry && !entry.is_default);
    if (special.length) valid = special;

    const parts = getPragueParts(now);
    const minute = parts.hour * 60 + parts.minute;
    const today = getPragueDay(now).getTime();
    for (let offset = 0; offset <= 7; offset++) {
        const day = new Date(today + offset * 86400000);
        const intervals = valid.filter(entry => String(entry.day_of_week).toLowerCase() === dayNames[day.getUTCDay()]).map(entry => {
            const opens = convertToMinutes(entry.opens);
            const closes = convertToMinutes(entry.closes);
            // "08:00–00:00" znamená do půlnoci.
            return { opens, closes: closes <= opens ? 24 * 60 : closes };
        }).sort((a, b) => a.opens - b.opens);

        for (const interval of intervals) {
            if (offset === 0 && interval.opens <= minute && minute < interval.closes) {
                // Nonstop provoz bývá zapsaný jako 00:00–23:59.
                const allDay = interval.opens === 0 && interval.closes >= 24 * 60 - 1;
                return { text: allDay ? 'otevřeno nonstop' : `otevřeno do ${formatMinutes(interval.closes)}`, open: true };
            }
            if (offset > 0 || interval.opens > minute) {
                const when = offset === 0 ? '' : offset === 1 ? 'zítra ' : `${weekdays[day.getUTCDay()]} `;
                return { text: `otevírá ${when}v ${formatMinutes(interval.opens)}`, open: false };
            }
        }
    }
    return { text: 'zavřeno', open: false };
}

async function getNearby(context, latitude, longitude) {
    const now = new Date();
    // Každý druh je samostatný dotaz; když jeden selže, ostatní se ukážou i tak.
    const results = await Promise.all(nearbyKinds.map(async kind => {
        let found;
        try {
            found = await invokeApi(context, kind.path, {
                latlng: formatLatLng(latitude, longitude), range: kind.range, group: kind.group, limit: kind.limit ?? 3,
            });
        }
        catch (error) { return { error }; }

        const nearest = getFeatures(found, latitude, longitude).filter(place => {
            const type = place.properties.type;
            return (!kind.group || !type?.group || type.group === kind.group) && (!kind.types || kind.types.includes(String(type?.description ?? '')));
        }).sort(byDistance)[0];
        if (!nearest) return null;

        const p = nearest.properties;
        // Úřady mají jen celou adresu "ulice, PSČ město, země"; do karty stačí ulice.
        const street = String(p.address?.street_address || String(p.address?.address_formatted ?? '').split(',')[0]);
        const status = getOpenStatus(p.opening_hours, now);
        // Služebny městské policie jméno nemají, tak je zastoupí adresa.
        const name = String(p.name || street || kind.label);
        const address = p.name ? street : String(p.cadastral_area ?? '');
        // Volný text navíc: otevírací doba sběrného dvora a zahrady, vybavení hřiště.
        let hours = String(p.operating_hours || list(p.properties).find(property => property?.id === 'doba')?.value || '');
        if (!hours && kind.path === '/v2/playgrounds') {
            hours = list(p.properties).map(property => String(property?.description ?? '')).filter(Boolean).join(', ');
        }
        return {
            place: {
                kind: kind.label,
                name,
                address,
                distance: formatDistance(nearest.distance),
                status: status?.text ?? '',
                statusColor: status?.open ? '#7BD88F' : '#8C93A8',
                hours,
                // Na počítači je v kartě místo na jeden řádek a zbytek se ukáže po najetí myší.
                detail: [name, address, hours].filter(Boolean).join('\n'),
            },
        };
    }));
    const places = results.filter(result => result?.place).map(result => result.place);
    // Když selže úplně všechno, je to chyba klíče nebo sítě a má být vidět.
    const failure = results.find(result => result?.error);
    if (!places.length && failure) throw failure.error;

    return {
        meta: 'nejbližší od každého',
        items: places,
        empty: places.length ? '' : 'Golemio v okolí nic nenašlo.',
    };
}

// ---- Nastavení: ověření klíče a hledání adresy ----

// Projde, když Golemio klíč přijme; jinak vyhodí chybu.
async function testToken(context) {
    // Nula: klíč se musí ověřit na síti, ne proti odpovědi z paměti.
    await invokeApi(context, '/v2/airqualitystations/indextypes', {}, 0);
    return true;
}

// Adresa odchází na server OpenStreetMap; aplikace na to upozorňuje.
async function findAddress(context, text) {
    const found = context.demo ? await readDemo(context.demo, 'nominatim-search') : await invokeHttp(`https://nominatim.openstreetmap.org/search${formatQuery({
        q: text, format: 'jsonv2', limit: 5, countrycodes: 'cz', 'accept-language': 'cs', addressdetails: 1,
    })}`, null, 'Nominatim');
    return list(found).filter(result => result?.display_name && result.lat && result.lon).map(result => ({
        name: String(result.display_name),
        label: formatPlace(result),
        latitude: Number(result.lat),
        longitude: Number(result.lon),
    }));
}

// Krátké jméno místa do pole s adresou a do záhlaví přehledu: "Korunní 586/2, Vinohrady".
// Celé jméno z Nominatimu je dlouhé a u domů začíná číslem popisným.
function formatPlace(result) {
    const a = result.address ?? {};
    const street = [a.road, a.house_number].filter(Boolean).join(' ');
    const main = result.name ? String(result.name) : a.house_number && a.road ? street : '';
    if (!main) return String(result.display_name).split(',').slice(0, 2).map(part => part.trim()).join(', ');
    const area = [a.quarter, a.suburb, a.city_district, a.district, a.town, a.village, a.city].find(part => part && part !== main);
    return [main, area].filter(Boolean).join(', ');
}

// V prohlížeči je všechno výš globální: obyčejný skript jde na rozdíl od modulu načíst bez serveru i s ním stejně.
// Node si funkce bere odsud.
if (typeof module === 'object') {
    module.exports = {
        defaultOptions, rateLimit, rateWindow, cacheSlow, cacheLive, cacheStatic, wasteColors,
        getOption, round, convertToApiError, formatQuery, formatLatLng, invokeHttp, waitRateLimit, testRateRoom, invokeApi, getCached,
        formatCompass, getDistance, formatDistance, getBoundingBox, readPosition, getPragueDay, convertToPragueTime, convertToDay,
        formatDay, formatClock, formatNumber, formatFormula, getWaste, getAir, getMicroclimate, getParking, findStops, getTransit,
        getVehicles, getAlerts, getCars, getCycling, testInRing, getDistrict, getOpenStatus, getNearby, testToken, findAddress, formatPlace,
    };
}
