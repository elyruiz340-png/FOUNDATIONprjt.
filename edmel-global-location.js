/* EDMEL shared global branch location controls. Uses PlaceDB CC0 data through the authenticated cache Edge Function. */
(function () {
  'use strict';
  const ids = {
    country: ['branchCreateCountry', 'managerBranchCountry'],
    region: ['branchCreateState', 'managerBranchState'],
    city: ['branchCreateCity', 'managerBranchCity'],
    timezone: ['branchCreateTimezone', 'managerBranchTimezone'],
    locale: ['branchCreateLocale', 'managerBranchLocale'],
    date: ['branchCreateDateFormat', 'managerBranchDateFormat'],
    time: ['branchCreateTimeFormat', 'managerBranchTimeFormat'],
    number: ['branchCreateNumberFormat', 'managerBranchNumberFormat']
  };
  const countryCache = { rows: null, promise: null };
  const regionCache = new Map();
  const mounted = new WeakSet();
  const key = s => String(s || '').toLowerCase().normalize('NFD').replace(/\p{Diacritic}/gu, '').replace(/[^a-z0-9]/g, '');
  const byId = list => list.map(id => document.getElementById(id)).find(Boolean) || null;
  function client() { try { return sb; } catch (_) { return null; } }
  async function invoke(body) {
    const c = client();
    if (!c?.functions?.invoke) throw new Error('Your session is not ready for global location search. Please refresh and sign in again.');
    const { data, error } = await c.functions.invoke('edmel-global-location-cache', { body });
    if (error) throw new Error(error.message || 'Global location lookup failed.');
    if (data?.error) throw new Error(data.error);
    return data;
  }
  function datalist(input, suffix) {
    const id = input.id + '_' + suffix + '_options';
    let list = document.getElementById(id);
    if (!list) { list = document.createElement('datalist'); list.id = id; input.insertAdjacentElement('afterend', list); }
    input.setAttribute('list', id);
    return list;
  }
  function fill(list, rows, value, label) {
    list.replaceChildren();
    for (const row of rows) {
      const option = document.createElement('option');
      option.value = value(row);
      if (label) option.label = label(row);
      list.append(option);
    }
  }
  async function countries() {
    if (countryCache.rows) return countryCache.rows;
    if (!countryCache.promise) countryCache.promise = invoke({ action: 'countries' }).then(data => {
      countryCache.rows = Array.isArray(data.countries) ? data.countries : [];
      return countryCache.rows;
    }).finally(() => { countryCache.promise = null; });
    return countryCache.promise;
  }
  async function regions(code) {
    if (regionCache.has(code)) return regionCache.get(code);
    const rows = await invoke({ action: 'regions', country_code: code });
    const values = Array.isArray(rows.regions) ? rows.regions.filter(r => r && r.name && !r.unassigned) : [];
    regionCache.set(code, values);
    return values;
  }
  function countryCode(input, rows) {
    const value = String(input?.value || '').trim();
    if (!value) return '';
    const found = rows.find(c => key(c.name) === key(value) || String(c.code).toUpperCase() === value.toUpperCase());
    return found ? String(found.code).toUpperCase() : '';
  }
  function setCountryCode(input, rows) {
    if (!input || !input.value) return;
    const found = rows.find(c => String(c.code).toUpperCase() === input.value.trim().toUpperCase());
    if (found) input.value = found.name;
  }
  function mount() {
    const country = byId(ids.country), region = byId(ids.region), city = byId(ids.city);
    if (!country || !region || !city || mounted.has(country)) return;
    mounted.add(country);
    const countryList = datalist(country, 'global_country');
    const regionList = datalist(region, 'global_region');
    const cityList = datalist(city, 'global_city');
    const timezone = byId(ids.timezone), locale = byId(ids.locale), date = byId(ids.date), time = byId(ids.time), number = byId(ids.number);
    if (timezone) datalist(timezone, 'global_timezone');
    if (locale) datalist(locale, 'global_locale');
    if (date) datalist(date, 'global_date');
    if (number) datalist(number, 'global_number');
    if (timezone && typeof Intl.supportedValuesOf === 'function') fill(timezone.list, Intl.supportedValuesOf('timeZone'), x => x);
    if (locale) fill(locale.list, ['en-US','en-GB','en-PH','en-CA','en-AU','ja-JP','zh-CN','zh-TW','ko-KR','fr-FR','fr-CA','de-DE','es-ES','es-MX','pt-BR','pt-PT','it-IT','ar-SA','hi-IN','id-ID','th-TH','vi-VN'], x => x);
    if (date) fill(date.list, ['MM/DD/YYYY','DD/MM/YYYY','YYYY-MM-DD','DD.MM.YYYY','YYYY/MM/DD'], x => x);
    if (number) fill(number.list, ['1,234.56','1.234,56','1 234,56','1’234.56','1234.56'], x => x);
    if (time && time.tagName === 'SELECT' && ![...time.options].some(o => o.value === '24h')) {
      time.add(new Option('12-hour', '12h')); time.add(new Option('24-hour', '24h'));
    }
    let activeCode = '';
    let activeRegionId = null;
    let searchTimer = 0;
    countries().then(rows => {
      fill(countryList, rows, c => c.name, c => c.code);
      setCountryCode(country, rows);
      const current = countryCode(country, rows);
      if (current) loadRegions(current, false);
    }).catch(err => console.warn('[EDMEL locations] Country list unavailable:', err.message));
    async function loadRegions(code, reset) {
      if (reset) { region.value = ''; city.value = ''; }
      activeCode = code;
      fill(regionList, [], x => x);
      fill(cityList, [], x => x);
      if (!code || !/^[A-Z]{2}$/.test(code)) return;
      try {
        const rows = await regions(code);
        if (activeCode !== code) return;
        fill(regionList, rows, r => r.name, r => r.iso_3166_2 || '');
        const selectedRegion = rows.find(r => key(r.name) === key(region.value));
        activeRegionId = selectedRegion?.id ?? null;
      } catch (err) { console.warn('[EDMEL locations] Region list unavailable:', err.message); }
    }
    country.addEventListener('change', async () => {
      const rows = await countries();
      const code = countryCode(country, rows);
      if (!rows.some(c => String(c.code).toUpperCase() === code)) {
        country.setCustomValidity('Choose a country from the global list or enter its ISO alpha-2 code.');
      } else {
        country.setCustomValidity('');
        country.value = rows.find(c => c.code === code).name;
      }
      if (timezone) timezone.value = '';
      if (locale) {
        const selected = rows.find(c => c.code === code);
        if (selected?.official_language) locale.value = selected.official_language + '-' + code;
      }
      await loadRegions(code, true);
    });
    region.addEventListener('change', async () => {
      city.value = ''; fill(cityList, [], x => x);
      const code = activeCode || countryCode(country, countryCache.rows || []);
      try { const rows = await regions(code); activeRegionId = rows.find(r => key(r.name) === key(region.value))?.id ?? null; }
      catch (_) { activeRegionId = null; }
    });
    city.addEventListener('input', () => {
      clearTimeout(searchTimer);
      const query = city.value.trim(), code = activeCode || countryCode(country, countryCache.rows || []);
      fill(cityList, [], x => x);
      if (query.length < 2 || !/^[A-Z]{2}$/.test(code)) return;
      searchTimer = setTimeout(async () => {
        try {
          const result = await invoke({ action: 'search', country_code: code, query });
          if (activeCode !== code || city.value.trim() !== query) return;
          const candidates = (result.places || []).filter(p => p && p.name && p.type === 'settlement');
          const inSelectedRegion = activeRegionId == null ? candidates : candidates.filter(p => Number(p.admin1_id ?? p.region_id ?? p.admin1) === Number(activeRegionId));
          const places = (inSelectedRegion.length ? inSelectedRegion : candidates).slice(0, 100);
          fill(cityList, places, p => p.name, p => p.population ? Number(p.population).toLocaleString() + ' population' : '');
          const exact = places.find(p => key(p.name) === key(query));
          if (exact?.timezone_id && timezone && !timezone.value) timezone.value = exact.timezone_id;
        } catch (err) { console.warn('[EDMEL locations] City suggestions unavailable:', err.message); }
      }, 280);
    });
  }
  function mountAll() {
    for (const pair of [ids.country]) for (const id of pair) {
      const input = document.getElementById(id);
      if (input) mount();
    }
  }
  const observer = new MutationObserver(mountAll);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mountAll);
  else mountAll();
  window.EDMELGlobalLocations = {
    countryCodeFor(inputId) {
      const input = document.getElementById(inputId);
      const rows = countryCache.rows || [];
      return countryCode(input, rows);
    },
    hasValidCountry(inputId) {
      const input = document.getElementById(inputId);
      if (!input?.value.trim()) return true;
      const rows = countryCache.rows || [];
      return rows.some(c => key(c.name) === key(input.value) || String(c.code).toUpperCase() === input.value.trim().toUpperCase());
    },
    countryNameFor(code) {
      const row = (countryCache.rows || []).find(c => c.code === String(code).toUpperCase());
      return row?.name || String(code || '');
    }
  };
})();