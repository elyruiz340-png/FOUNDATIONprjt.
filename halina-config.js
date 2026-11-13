/* HALINA CENTRAL CONFIGURATION FOUNDATION
 * Shared, read-only configuration utilities for all restaurant dashboards.
 * Business settings remain stored in Supabase; this file does not write data.
 */
(function (window) {
  'use strict';
  const DEFAULTS = Object.freeze({
    currency: 'USD',
    country_code: 'US',
    timezone: 'America/Chicago',
    locale: 'en-US'
  });
  const LOCALES = Object.freeze({
    USD:'en-US',PHP:'en-PH',EUR:'de-DE',GBP:'en-GB',CAD:'en-CA',
    AUD:'en-AU',NZD:'en-NZ',SGD:'en-SG',JPY:'ja-JP',KRW:'ko-KR',
    INR:'en-IN',AED:'en-AE',SAR:'en-SA',THB:'th-TH',MYR:'ms-MY',
    IDR:'id-ID',VND:'vi-VN',CHF:'de-CH',CNY:'zh-CN',HKD:'zh-HK'
  });
  const SUPPORTED_CURRENCIES = Object.freeze(Object.keys(LOCALES));
  function normalizeProfile(profile) {
    const source = profile && typeof profile === 'object' ? profile : {};
    const currency = String(source.currency || DEFAULTS.currency).trim().toUpperCase();
    const timezone = String(source.timezone || DEFAULTS.timezone).trim();
    return Object.freeze({
      ...source,
      currency: /^[A-Z]{3}$/.test(currency) ? currency : DEFAULTS.currency,
      timezone: timezone || DEFAULTS.timezone,
      country_code: String(source.country_code || DEFAULTS.country_code).trim().toUpperCase()
    });
  }
  function localeFor(currency, preferredLocale) {
    const code = String(currency || DEFAULTS.currency).toUpperCase();
    return preferredLocale || LOCALES[code] || DEFAULTS.locale;
  }
  function formatMoney(amount, currency, preferredLocale) {
    const code = String(currency || DEFAULTS.currency).toUpperCase();
    const value = Number(amount);
    return new Intl.NumberFormat(localeFor(code, preferredLocale), {
      style:'currency',
      currency:/^[A-Z]{3}$/.test(code) ? code : DEFAULTS.currency,
      minimumFractionDigits:2,
      maximumFractionDigits:2
    }).format(Number.isFinite(value) ? value : 0);
  }
  function getCurrentProfile() {
    return normalizeProfile(window.HALINA_RESTAURANT_PROFILE || {});
  }
  function applyProfile(profile) {
    const normalized = normalizeProfile(profile);
    window.HALINA_RESTAURANT_PROFILE = normalized;
    window.dispatchEvent(new CustomEvent('halinaconfigurationchanged', {detail:normalized}));
    return normalized;
  }
  window.HALINA_CONFIG = Object.freeze({
    defaults:DEFAULTS,
    supportedCurrencies:SUPPORTED_CURRENCIES,
    localeFor,formatMoney,normalizeProfile,getCurrentProfile,applyProfile
  });
})(window);
