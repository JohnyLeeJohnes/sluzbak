// Mobilní Službák: obsluha stránky. Obrazovky jsou popsané v index.html, data čte data.js.
// Je to přepis Sluzbak.ps1, funkce se jmenují stejně. Běží v aplikaci Bránocesta pro Android; v prohlížeči na počítači
// jde otevřít k vyzkoušení.
//   index.html         spustí aplikaci
//   index.html#demo    místo sítě čte ukázková data ze složky demo (bez klíče i bez internetu)
'use strict';

const demo = location.hash === '#demo';
const storageKey = 'sluzbak';
const stopsKey = 'sluzbak.stops';
// Ukázkové odpovědi leží v repozitáři vedle složky mobile a čtou se přes HTTP, takže ukázka potřebuje server.
const readDemoFile = async file => {
    const response = await fetch(`../demo/${file}`);
    return response.ok ? response.text() : null;
};

// Ukázkové místo: k náměstí Míru patří soubory ve složce demo.
const demoPlace = { name: 'Náměstí Míru, Praha 2', latitude: 50.0753, longitude: 14.4379 };
const unnamed = 'Vlastní místo';

// Sekce (karty) přehledu v pořadí, v jakém jsou na stránce. Ke každé patří funkce get<Sekce> v data.js,
// v přehledu prvky <sekce>Card, <sekce>Toggle (záhlaví, které kartu sbaluje), <sekce>Meta, <sekce>State
// a <sekce>Body, v nastavení štítek <sekce>Chip a dole v tomhle souboru funkce v renderers, která kartu poskládá.
const sections = ['transit', 'vehicles', 'waste', 'alerts', 'cars', 'cycling', 'air', 'microclimate', 'parking', 'nearby'];
const loaders = {
    transit: getTransit, vehicles: getVehicles, waste: getWaste, alerts: getAlerts, cars: getCars,
    cycling: getCycling, air: getAir, microclimate: getMicroclimate, parking: getParking, nearby: getNearby,
};
// Sekce, kde jde o minuty, se obnovují s odjezdy; ostatním stačí jednou za deset minut.
const live = ['transit', 'vehicles'];
// Sekce, které počkají, až se dočtou ty ostatní. Všechny karty naráz se do limitu API nevejdou (první načtení
// je přes 30 dotazů, limit 18 za 8 s); bez toho by na místo v limitu čekaly odjezdy.
const background = ['parking', 'nearby', 'cars', 'cycling'];
// Sekce, která se nespojila, to zkusí znovu dřív než za deset minut.
const retryEvery = 30000;
// Sekce, která kvůli limitu API něco odložila (pending), to zkusí, jakmile se okno limitu vyprázdní.
const retrySoon = (rateWindow + 1) * 1000;
// Zastávky kolem místa se v telefonu pamatují týden, viz loadStops.
const stopsAge = 7 * 86400000;

// Číselné volby: nejmenší a největší povolená hodnota. Výchozí hodnoty jsou v defaultOptions (data.js),
// v nastavení má každá pole <volba>Box.
const limits = {
    stopsRange: [100, 2000],
    wasteRange: [100, 2000],
    parkingRange: [200, 5000],
    departures: [3, 30],
    refresh: [15, 600],
};

// Prvky stránky podle id.
const ui = {};
for (const element of document.querySelectorAll('[id]')) ui[element.id] = element;

const state = {
    // Uložené nastavení: { token, name, latitude, longitude, options }, kde options jsou číselné volby,
    // hidden = sekce, které uživatel v přehledu nechce, a collapsed = sekce, které má sbalené.
    saved: null,
    trial: false,         // přehled s ukázkovými daty, nic se neukládá
    generation: 0,        // zvýší se při změně místa; výsledky starších dotazů se zahodí
    stops: null,          // zastávky v okolí; hledají se jen jednou, je to nejdražší dotaz
    running: new Map(),   // sekce, která se právě načítá -> její generation
    updated: null,
    manual: false,        // načítání, o které si řekl uživatel; jen to se v záhlaví ohlašuje
    finding: false,       // běží hledání adresy
    found: null,          // naposledy nalezená adresa; Enter v poli s ní ukládá, místo aby hledal znovu
    collapsed: [],        // sbalené sekce: ukazují jen záhlaví a nenačítají se
    shows: {},            // sekce -> co má pod záhlavím: 'body' (data), jinak stavový text
    due: {},              // sekce -> kdy se má znovu načíst (chybí = hned, jak bude vidět)
    district: '',         // městská část, ve které místo leží
};

function el(tag, className, ...children) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    // Prázdné texty a chybějící části se vynechají, ať je nemusí hlídat každá karta zvlášť.
    element.append(...children.filter(child => child || child === 0));
    return element;
}

function testDemo() { return demo || state.trial; }
function getPlace() { return state.trial ? demoPlace : state.saved; }

function getDefaultOptions() {
    const options = { hidden: [], collapsed: [] };
    for (const name in limits) options[name] = defaultOptions[name];
    return options;
}
// Ukázka z tlačítka běží vždy s výchozími volbami, ať vypadá pro každého stejně.
function getOptions() { return state.trial || !state.saved ? getDefaultOptions() : state.saved.options; }
function getSections() {
    const hidden = getOptions().hidden;
    return sections.filter(name => !hidden.includes(name));
}
// Sekce, které mají co ukazovat: zapnuté a rozbalené. Jen ty se načítají a obnovují.
function getActiveSections() { return getSections().filter(name => !state.collapsed.includes(name)); }
// Za jak dlouho se má sekce načíst znovu. Pomalé sekce drží krok s pamětí odpovědí v data.js:
// dřív by stejně dostaly jen to, co už mají.
function getEvery(name) { return (live.includes(name) ? getOptions().refresh : cacheSlow) * 1000; }

// Co není celé číslo, se změní na výchozí hodnotu; číslo mimo meze na nejbližší povolené.
function convertToOption(name, value) {
    if (!/^\s*\d+\s*$/.test(`${value ?? ''}`)) return defaultOptions[name];
    return Math.max(limits[name][0], Math.min(limits[name][1], Number(value)));
}

// Všechny dotazy sdílejí jednu frontu časů, podle které data.js hlídá limit API, a jednu paměť odpovědí.
const limiter = [];
const cache = new Map();
function getContext() {
    return testDemo()
        ? { token: '', demo: readDemoFile, cache, options: getOptions() }
        : { token: state.saved.token, demo: null, limiter, cache, options: getOptions() };
}

// Chyba z datové vrstvy má druh a českou hlášku. Chyby bez druhu nejsou ze sítě, ale z našeho kódu; ať je to z hlášky poznat.
function getMessage(error) {
    return error.kind ? error.message : `Tohle se nepovedlo zpracovat: ${error.message}`;
}

// ---- Nastavení v úložišti ----
// Jediné, co si aplikace pamatuje, a má stejný tvar jako settings.json na počítači. Ochrana Windows (DPAPI),
// kterou počítač šifruje klíč, tu není: v telefonu leží klíč v úložišti prohlížeče tak, jak je.

function readSettings() {
    try {
        const saved = JSON.parse(localStorage.getItem(storageKey));
        if (saved.token && saved.latitude != null && saved.longitude != null) {
            // Volby mohou chybět nebo být přepsané ručně; convertToOption si poradí s obojím.
            const options = {
                hidden: list(saved.options?.hidden).filter(name => sections.includes(name)),
                collapsed: list(saved.options?.collapsed).filter(name => sections.includes(name)),
            };
            for (const name in limits) options[name] = convertToOption(name, saved.options?.[name]);
            return {
                token: String(saved.token),
                name: saved.place ? String(saved.place) : unnamed,
                latitude: Number(saved.latitude),
                longitude: Number(saved.longitude),
                options,
            };
        }
    }
    catch { }   // Chybějící, poškozené nebo zakázané úložiště = první spuštění.
    return null;
}

function saveSettings(settings) {
    localStorage.setItem(storageKey, JSON.stringify({
        token: settings.token, place: settings.name, latitude: settings.latitude, longitude: settings.longitude, options: settings.options,
    }));
    // Prohlížeč jinak smí data stránky, na kterou se dlouho nechodí, uklidit.
    navigator.storage?.persist?.();
}

// Zastávky kolem místa. Počítač je hledá při každém spuštění; v telefonu by to pokaždé znamenalo stáhnout přes
// mobilní data celý seznam zastávek PID, proto si je pro uložené místo a okruh týden pamatuje.
function getStopsKey() {
    const place = getPlace();
    return `${formatLatLng(place.latitude, place.longitude)}|${getOptions().stopsRange}`;
}

function loadStops() {
    if (testDemo()) return null;
    try {
        const saved = JSON.parse(localStorage.getItem(stopsKey));
        return saved.key === getStopsKey() && Date.now() - saved.at < stopsAge ? saved.stops : null;
    }
    catch { return null; }
}

function saveStops(stops) {
    if (testDemo()) return;
    // Když se to nezapíše, zastávky se jen příště hledají znovu.
    try { localStorage.setItem(stopsKey, JSON.stringify({ key: getStopsKey(), at: Date.now(), stops })); }
    catch { }
}

// ---- Přehled ----

function formatCoordinate(value) { return String(Number(value.toFixed(5))); }

function showView(name) {
    for (const view of ['setupView', 'dashboardView']) ui[view].hidden = view !== name;
}

// Pod záhlavím karty je buď stavový text, nebo data; sbalená karta ukazuje jen záhlaví.
function updateCard(name) {
    const collapsed = state.collapsed.includes(name);
    const shows = collapsed ? '' : state.shows[name] === 'body' ? 'body' : 'state';
    ui[`${name}State`].hidden = shows !== 'state';
    ui[`${name}Body`].hidden = shows !== 'body';
    // Sbalená karta se nenačítá, takže by údaj v záhlaví jen stárnul.
    ui[`${name}Meta`].hidden = collapsed;
    ui[`${name}Toggle`].setAttribute('aria-expanded', !collapsed);
}

// Stav sekce místo dat: načítání, prázdno nebo chyba.
function showState(name, text, isError = false) {
    ui[`${name}State`].textContent = text;
    ui[`${name}State`].classList.toggle('danger', isError);
    state.shows[name] = 'state';
    updateCard(name);
}

function getLoadingText(name) { return name === 'transit' && !state.stops ? 'Hledám zastávky v okolí…' : 'Načítám…'; }

// Sbalení se pamatuje hned, bez tlačítka Uložit. Ukázka z tlačítka nic neukládá.
function setCollapsed(name, collapsed) {
    state.collapsed = sections.filter(section => section === name ? collapsed : state.collapsed.includes(section));
    if (state.saved && !state.trial) {
        state.saved.options.collapsed = state.collapsed;
        // Když se to nezapíše, karta jen příště začne rozbalená; kvůli tomu se stránka hláškou nepřerušuje.
        try { saveSettings(state.saved); } catch { }
    }
    // Co mezitím zestárlo, se po rozbalení neukáže jako aktuální: nejdřív se načte znovu.
    if (!collapsed && !(Date.now() < state.due[name])) {
        ui[`${name}Meta`].textContent = '';
        showState(name, getLoadingText(name));
    }
    updateCard(name);
    if (!collapsed) startDue();
}

function resetSections() {
    state.generation++;
    state.stops = loadStops();
    state.due = {};
    state.updated = null;
    state.district = '';
    for (const name of sections) {
        ui[`${name}Meta`].textContent = '';
        ui[`${name}Body`].replaceChildren();
        showState(name, getLoadingText(name));
    }
}

function startSection(name) {
    // Termín dalšího načtení se posune hned, ať se sekce nespouští při každém tiknutí časovače.
    state.due[name] = Date.now() + getEvery(name);
    const generation = state.generation;
    // Předchozí načítání téže sekce ještě běží.
    if (state.running.get(name) === generation) return;
    state.running.set(name, generation);

    const place = getPlace();
    const work = loaders[name](getContext(), place.latitude, place.longitude, state.stops);
    work.then(data => ({ ok: true, data }), error => ({ ok: false, kind: error.kind ?? '', message: getMessage(error) }))
        .then(result => completeSection(name, generation, result));
}

// Běží v téhle generaci ještě některá z karet, na které ty v background čekají?
function testLoading() {
    return [...state.running].some(([name, generation]) => generation === state.generation && !background.includes(name));
}

// Načte, co je na řadě. Vypnuté a sbalené karty se nestahují: šetří to API i mobilní data.
function startDue() {
    const due = getActiveSections().filter(name => !(Date.now() < state.due[name]));
    for (const name of due) if (!background.includes(name)) startSection(name);
    // Karty v background přijdou na řadu, až když se žádná z ostatních nenačítá.
    if (testLoading()) return;
    for (const name of due) if (background.includes(name)) startSection(name);
}

function completeSection(name, generation, result) {
    if (state.running.get(name) === generation) state.running.delete(name);
    if (generation !== state.generation) return;

    if (result.ok) {
        const data = result.data;
        if (name === 'transit') {
            if (!state.stops) saveStops(data.stops);
            state.stops = data.stops;
        }
        // Další obnovení se počítá od doručení dat, ne od spuštění: paměť odpovědí je tou dobou už jistě prošlá
        // a obnovení opravdu přinese nová data. Sekce, která něco odložila kvůli limitu API, to zkusí hned po něm.
        state.due[name] = Date.now() + (data.pending ? retrySoon : getEvery(name));
        state.updated = new Date();
        ui[`${name}Meta`].textContent = data.meta;
        if (data.empty) showState(name, data.empty);
        else {
            try {
                ui[`${name}Body`].replaceChildren(...renderers[name](data).filter(Boolean));
                state.shows[name] = 'body';
                updateCard(name);
            }
            catch (error) { showState(name, getMessage(error), true); }
        }
    }
    else {
        // Při chybě data mizí: starý odjezd nebo obsazenost by vypadaly jako aktuální.
        showState(name, result.message, true);
        // Výpadek spojení bývá chvilkový, tak se to zkusí brzy znovu. Klíč, který k datům nesmí, se sám nespraví.
        const retry = Date.now() + retryEvery;
        if (!['Unauthorized', 'Forbidden', 'NotFound'].includes(result.kind) && state.due[name] > retry) state.due[name] = retry;
    }
    // Na tuhle kartu mohly čekat ty z background.
    if (testVisible()) startDue();
    updateHeader();
}

// Obnovení, o které si řekl uživatel: projde všechny rozbalené karty. Na síť se přitom jde jen pro to, co už
// není čerstvé (viz paměť odpovědí v data.js), takže opakované ťukání API nezatíží.
function updateSections() {
    state.manual = true;
    // Termíny se zahodí a o pořadí se postará startDue.
    for (const name of getActiveSections()) delete state.due[name];
    startDue();
    updateHeader();
}

// Schová karty, které uživatel vypnul.
function updateLayout() {
    const shown = getSections();
    for (const name of sections) {
        ui[`${name}Card`].hidden = !shown.includes(name);
        updateCard(name);
    }
    if (testVisible()) startDue();
}

function updateHeader() {
    const busy = state.manual && [...state.running.values()].includes(state.generation);
    if (!busy) state.manual = false;
    ui.refreshButton.disabled = busy;
    ui.updatedText.textContent =
        busy ? 'načítám…'
        : state.updated ? `aktualizováno ${state.updated.getHours()}:${two(state.updated.getMinutes())}`
        : '';
}

function updatePlace() {
    const place = getPlace();
    ui.placeText.textContent = place.name;
    ui.coordinatesText.textContent = [`${formatCoordinate(place.latitude)}, ${formatCoordinate(place.longitude)}`, state.district].filter(Boolean).join(' · ');
}

function showDashboard(reload = false) {
    ui.demoBadge.hidden = !testDemo();
    showView('dashboardView');
    if (reload) {
        resetSections();
        state.manual = true;
        scrollTo(0, 0);
        // Městská část je jen do záhlaví; když se nezjistí, zůstanou tam samotné souřadnice.
        const place = getPlace();
        const generation = state.generation;
        getDistrict(getContext(), place.latitude, place.longitude).then(district => {
            if (generation !== state.generation) return;
            state.district = district;
            updatePlace();
        }, () => { });
    }
    updatePlace();
    // updateLayout zároveň spustí načítání toho, co je na řadě.
    updateLayout();
    updateHeader();
}

// Přehled na pozadí nebo schovaný za nastavením nic nestahuje; po návratu se obnoví hned.
function testVisible() { return !ui.dashboardView.hidden && !document.hidden; }

// ---- Karty ----
// Každá funkce dostane objekt z data.js a vrátí prvky, které přijdou do <sekce>Body.

// Číslo linky v její barvě.
function showRoute(item) {
    const route = el('span', 'route', item.route);
    route.style.background = item.color;
    route.style.color = item.routeTextColor;
    return route;
}

function colored(element, color) {
    element.style.color = color;
    return element;
}

const renderers = {
    transit: data => [
        ...data.departures.map(item => {
            const row = el('div', 'line two',
                showRoute(item),
                el('span', 'what grow', el('b', '', item.headsign), el('span', 'small', item.stop)),
                el('span', 'when', colored(el('span', '', item.in), item.inColor),
                    el('span', 'small', item.time, item.delay && el('span', 'accent', ` ${item.delay}`))));
            row.style.opacity = item.opacity;
            return row;
        }),
        ...data.infotexts.map(item => el('p', 'note', item.text)),
    ],

    vehicles: data => data.items.map(item => el('div', 'line',
        showRoute(item),
        el('span', 'grow', el('b', '', item.headsign), ' ', el('span', 'small', item.state)),
        item.delay && el('span', 'small accent', item.delay),
        el('span', 'small', item.distance))),

    waste: data => [
        ...data.stations.map(station => el('div', 'block',
            el('div', 'line', el('b', 'grow', station.name), el('span', 'small', station.distance)),
            ...station.kinds.map(kind => {
                const dot = el('i', 'dot');
                dot.style.background = kind.color;
                // Vpravo zaplnění kontejneru podle senzoru a příští svoz.
                return el('div', 'line', dot,
                    el('span', 'grow', kind.type, ' ', el('span', 'small', kind.pickDays)),
                    kind.fill && el('span', 'small', kind.fill), kind.next && el('b', '', kind.next));
            }))),
        // Klíč bez přístupu k velkoobjemovým kontejnerům: nadpis se schová, seznam i poznámka jsou prázdné.
        data.showBulky && el('h3', '', 'Velkoobjemové kontejnery'),
        ...data.bulky.map(item => el('div', 'line two',
            el('span', 'what grow', el('b', '', item.when), el('span', 'small', item.street)),
            el('span', 'small', item.distance))),
        data.bulkyNote && el('p', 'small', data.bulkyNote),
    ],

    alerts: data => [
        ...data.items.map(item => {
            const alert = el('div', 'alert', el('p', '', item.text),
                el('p', 'small', item.stops, ' ', el('span', 'until', item.until)));
            alert.style.borderColor = item.color;
            return alert;
        }),
        data.more && el('p', 'small', data.more),
    ],

    cars: data => data.items.map(item => el('div', 'line two',
        el('span', 'what grow', el('b', '', item.name), el('span', 'small', item.detail)),
        el('span', 'small', item.distance))),

    cycling: data => [
        el('p', '', el('span', 'figure', data.total), ' ', el('span', 'small', data.caption)),
        ...data.items.map(item => el('div', 'line', el('span', 'grow small', item.name), el('b', '', item.value))),
    ],

    air: data => {
        const index = colored(el('span', 'index', data.index), data.indexTextColor);
        index.style.background = data.indexColor;
        return [
            el('div', 'line', el('span', 'grow', index), el('span', 'small', data.updated)),
            ...data.components.map(item => el('div', 'line',
                el('span', 'formula', item.name), el('span', 'grow small', item.detail), el('b', '', item.value))),
        ];
    },

    microclimate: data => [
        el('div', 'values', ...data.values.map(item => el('div', 'what', el('span', 'small', item.name), el('b', '', item.value)))),
        data.updated && el('p', 'small', data.updated),
    ],

    parking: data => [
        ...data.items.map(item => el('div', 'line two',
            el('span', 'what grow', el('b', '', item.name), el('span', 'small', item.detail)),
            el('span', '', colored(el('b', '', item.free), item.freeColor), ' ', el('span', 'small', item.capacity)))),
        data.machine && el('p', 'small', data.machine),
    ],

    // Na počítači se zbytek ukáže po najetí myší; v telefonu má otevírací doba a vybavení vlastní řádek.
    nearby: data => data.items.map(item => el('div', 'block nearby',
        el('div', 'line', el('b', 'grow', item.name), el('span', 'small', item.distance)),
        el('div', 'line', el('span', 'grow small', el('b', '', item.kind), ' ', item.address),
            item.status && colored(el('span', 'small', item.status), item.statusColor)),
        item.hours && el('p', 'small hours', item.hours))),
};

// ---- Nastavení na stránce ----

function setSetupStatus(text, isError = false) {
    ui.setupStatus.textContent = text;
    ui.setupStatus.classList.toggle('danger', isError);
}

function showSetup() {
    const saved = state.saved;
    ui.tokenBox.value = saved ? saved.token : '';
    ui.addressBox.value = saved && saved.name !== unnamed ? saved.name : '';
    ui.latitudeBox.value = saved ? formatCoordinate(saved.latitude) : '';
    ui.longitudeBox.value = saved ? formatCoordinate(saved.longitude) : '';
    const options = saved ? saved.options : getDefaultOptions();
    for (const name in limits) ui[`${name}Box`].value = options[name];
    for (const name of sections) ui[`${name}Chip`].checked = !options.hidden.includes(name);
    showResults([]);
    // Uložená adresa už souřadnice má: Enter v poli ji uloží, hledat se začne, až ji uživatel přepíše.
    state.found = ui.addressBox.value || null;
    setSetupStatus('');

    // Je-li se kam vrátit, nabízí se návrat; jinak ukázka, ať jde aplikace zkusit i bez klíče.
    const canReturn = Boolean(saved) || state.trial;
    ui.backButton.hidden = !canReturn;
    ui.demoButton.hidden = canReturn;

    showView('setupView');
    scrollTo(0, 0);
}

// "50,0753", "50.0753" i "50.0753°"; nic nevrátí, když to není číslo v rozsahu.
function readCoordinate(text, limit) {
    const clean = text.replace(',', '.').replace(/[°\s]/g, '');
    return /^[+-]?(\d+\.?\d*|\.\d+)$/.test(clean) && Math.abs(Number(clean)) <= limit ? Number(clean) : null;
}

// S #demo se neptáme sítě ani tady, aby šlo nastavení projít bez klíče.
function getSetupContext(token) {
    return { token, demo: demo ? readDemoFile : null, limiter };
}

// Nalezené adresy pod polem; ťuknutí adresu vybere.
function showResults(found) {
    ui.resultsList.replaceChildren(...found.map(place => {
        const row = el('button', '', place.name);
        row.type = 'button';
        row.onclick = () => selectPlace(place, row);
        return row;
    }));
    ui.resultsList.hidden = !found.length;
}

async function findPlace() {
    const text = ui.addressBox.value.trim();
    if (!text) {
        setSetupStatus('Napiš adresu, třeba „Korunní 2, Praha“.', true);
        return;
    }
    if (state.finding) return;

    state.finding = true;
    setSetupStatus('Hledám…');
    let found;
    try { found = await findAddress(getSetupContext(''), text); }
    catch (error) {
        setSetupStatus(getMessage(error), true);
        return;
    }
    finally { state.finding = false; }

    showResults(found);
    if (!found.length) {
        setSetupStatus('Nic jsem nenašel. Zkus adresu napsat přesněji.', true);
        return;
    }
    // První výsledek bývá ten pravý, tak se rovnou vybere (selectPlace vyplní pole adresy i souřadnice).
    selectPlace(found[0], ui.resultsList.firstChild);
    setSetupStatus(found.length > 1 ? 'Vybral jsem první výsledek. Jestli nesedí, ťukni na jiný.' : 'Adresa nalezena. Tlačítko níž ji uloží.');
}

// Vybraná adresa se propíše do pole (uloží se jako jméno místa) a do souřadnic.
function selectPlace(place, row) {
    for (const other of ui.resultsList.children) other.setAttribute('aria-pressed', other === row);
    ui.latitudeBox.value = formatCoordinate(place.latitude);
    ui.longitudeBox.value = formatCoordinate(place.longitude);
    ui.addressBox.value = place.label;
    // Další Enter v poli s touhle adresou už nehledá znovu, ale ukládá.
    state.found = place.label;
}

async function saveSetup() {
    const token = ui.tokenBox.value.trim();
    if (!token) {
        setSetupStatus('Vlož klíč ke Golemio API.', true);
        ui.tokenBox.focus();
        return;
    }
    const latitude = readCoordinate(ui.latitudeBox.value, 90);
    const longitude = readCoordinate(ui.longitudeBox.value, 180);
    if (latitude == null || longitude == null) {
        setSetupStatus('Najdi adresu, nebo vyplň souřadnice (třeba 50,0753 a 14,4379).', true);
        return;
    }

    // Sbalení karet se v nastavení nemění, jen se s ním uloží to, co je teď v přehledu.
    const options = { hidden: sections.filter(name => !ui[`${name}Chip`].checked), collapsed: [...state.collapsed] };
    if (options.hidden.length === sections.length) {
        setSetupStatus('Nech zapnutou aspoň jednu kartu.', true);
        return;
    }
    for (const name in limits) {
        options[name] = convertToOption(name, ui[`${name}Box`].value);
        // Ať je ve formuláři vidět, co se opravdu uloží.
        ui[`${name}Box`].value = options[name];
    }

    const settings = { token, name: ui.addressBox.value.trim() || unnamed, latitude, longitude, options };
    // Než se klíč ověří, formulář zamrzne, aby se mezitím nedalo odejít jinam.
    ui.setupView.inert = true;
    setSetupStatus('Ověřuju klíč…');
    try { await testToken(getSetupContext(token)); }
    catch (error) {
        setSetupStatus(error.kind === 'Unauthorized' ? 'Golemio tenhle klíč odmítlo. Zkontroluj, že je zkopírovaný celý.' : getMessage(error), true);
        return;
    }
    finally { ui.setupView.inert = false; }

    try { saveSettings(settings); }
    catch (error) {
        setSetupStatus(`Nastavení se nepodařilo uložit: ${error.message}`, true);
        return;
    }
    // Jiný klíč může mít k datům jiný přístup; co si paměť odpovědí pamatuje, patřilo tomu starému.
    if (state.saved && state.saved.token !== token) cache.clear();
    state.saved = settings;
    state.trial = false;
    showDashboard(true);
}

// ---- Stránka ----

// Když Službáka pustila Bránocesta, nechala v úložišti téhle záložky (sessionStorage) pod jménem branocesta svou
// adresu. Tlačítko na ni vrátí. Stránka otevřená rovnou (v prohlížeči na počítači) tam nic nemá a tlačítka zůstanou schovaná.
let gateway = null;
try { gateway = sessionStorage.getItem('branocesta'); }
catch { }   // úložiště je zakázané
if (gateway) {
    for (const button of [ui.gatewayButton, ui.setupGatewayButton]) {
        button.hidden = false;
        // replace: Službák po sobě nenechá krok v historii, takže se do něj z brány nejde vrátit gestem zpět.
        button.onclick = () => location.replace(gateway);
    }
}

// Tlačítko Zpět na telefonu (volá ho aplikace Bránocesta pro Android): z nastavení vrátí do přehledu, je-li
// do čeho. Jinak vrací false a aplikace se vrátí do brány.
function goBack() {
    if (ui.setupView.hidden || ui.backButton.hidden) return false;
    // Zatímco se ověřuje klíč, z nastavení se neodchází.
    if (!ui.setupView.inert) showDashboard();
    return true;
}

// ---- Nastavení ----

ui.findButton.onclick = findPlace;
// Enter v poli adresy: adresa, která se už našla, se uloží; nová nebo změněná se nejdřív hledá.
ui.addressBox.onkeydown = event => {
    if (event.key !== 'Enter') return;
    event.preventDefault();
    if (state.found && ui.addressBox.value.trim() === state.found) saveSetup();
    else findPlace();
};
// Odeslání formuláře je tlačítko Uložit i Enter na klávesnici telefonu v ostatních polích.
ui.setupForm.onsubmit = event => {
    event.preventDefault();
    saveSetup();
};

// Pole s čísly berou jen číslice a po opuštění se srovnají do povolených mezí.
for (const name in limits) {
    const box = ui[`${name}Box`];
    box.oninput = () => { box.value = box.value.replace(/\D/g, ''); };
    box.onblur = () => { box.value = convertToOption(name, box.value); };
}
ui.limitsHint.textContent = 'Povolené hodnoty: zastávky {0} m, tříděný odpad {1} m, parkoviště {2} m, odjezdů {3}, obnovování po {4} s. Jiné číslo se upraví na nejbližší povolené.'
    .replace(/\{(\d)\}/g, (match, index) => Object.values(limits)[index].join('–'));

ui.backButton.onclick = () => showDashboard();
ui.demoButton.onclick = () => {
    state.trial = true;
    showDashboard(true);
};

// ---- Přehled ----

ui.refreshButton.onclick = updateSections;
ui.settingsButton.onclick = showSetup;
for (const name of sections) ui[`${name}Toggle`].onclick = () => setCollapsed(name, !state.collapsed.includes(name));

setInterval(() => {
    if (testVisible()) startDue();
    updateHeader();
}, 1000);
// Po návratu do aplikace se nečeká na další tiknutí.
document.addEventListener('visibilitychange', () => { if (testVisible()) startDue(); });

state.saved = readSettings();
if (state.saved) {
    state.collapsed = [...state.saved.options.collapsed];
    showDashboard(true);
}
else if (demo) {
    state.trial = true;
    showDashboard(true);
}
else showSetup();
