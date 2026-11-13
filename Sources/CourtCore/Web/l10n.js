// Browser-display copy. The camera serves this file with l10n.json. Simplified Chinese is the
// key and the fallback: a missing entry, a failed fetch, or an unsupported language stays Chinese.
// ?lang= overrides navigator.languages so a screenshot run can force one language on this machine.

const LOCALES = ["zh-Hant", "en", "ja", "de", "fr"];

let catalog = { strings: {} };
let choice = { language: "zh-Hans", format: "zh-CN" };

function parse(tag) {
  if (!tag) return null;
  const parts = tag.split(/[-_]/);
  const head = (parts[0] || "").toLowerCase();
  const region = parts.slice(1).find((part) => part.length === 2 && /^[A-Za-z]+$/.test(part));
  const regionUp = region ? region.toUpperCase() : "";
  const script = parts.slice(1).find((part) => part.length === 4);
  const scriptLow = script ? script.toLowerCase() : "";
  if (head === "zh") {
    const traditional = scriptLow === "hant" || regionUp === "TW" || regionUp === "HK" || regionUp === "MO";
    if (traditional) {
      const format = regionUp === "HK" ? "zh_HK" : regionUp === "MO" ? "zh_MO" : "zh_TW";
      return { language: "zh-Hant", format };
    }
    return { language: "zh-Hans", format: regionUp === "SG" ? "zh_SG" : "zh_CN" };
  }
  if (head === "en") return { language: "en", format: regionUp === "GB" ? "en_GB" : regionUp ? `en_${regionUp}` : "en_US" };
  if (head === "ja") return { language: "ja", format: regionUp ? `ja_${regionUp}` : "ja_JP" };
  if (head === "de") return { language: "de", format: regionUp ? `de_${regionUp}` : "de_DE" };
  if (head === "fr") return { language: "fr", format: regionUp ? `fr_${regionUp}` : "fr_FR" };
  return null;
}

function pick() {
  const query = new URLSearchParams(location.search).get("lang");
  const tags = query ? [query] : [...(navigator.languages || [navigator.language || ""])];
  for (const tag of tags) {
    const parsed = parse(tag);
    if (parsed) return parsed;
  }
  return { language: "zh-Hans", format: "zh-CN" };
}

export function language() { return choice.language; }

/// BCP-47 tag for Intl. Simplified Chinese keeps zh-CN, which is what the page used before.
export function dateTag() {
  if (choice.language === "zh-Hans") return "zh-CN";
  return choice.format.replaceAll("_", "-");
}

export function t(source) {
  if (!source || choice.language === "zh-Hans") return source;
  const row = catalog.strings && catalog.strings[source];
  return (row && row[choice.language]) || source;
}

export function fmt(source, ...args) {
  let result = t(source);
  args.forEach((arg, index) => {
    result = result.split(`%${index + 1}$@`).join(String(arg));
  });
  return result;
}

export function numberText(value, digits = 0) {
  if (choice.language === "zh-Hans") {
    return digits === 0 ? String(Math.round(Number(value))) : Number(value).toFixed(digits);
  }
  return new Intl.NumberFormat(dateTag(), {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(Number(value));
}

export function applyDocument(root = document) {
  root.querySelectorAll("[data-l10n]").forEach((element) => {
    element.textContent = t(element.dataset.l10n);
  });
  root.querySelectorAll("[data-l10n-aria]").forEach((element) => {
    element.setAttribute("aria-label", t(element.dataset.l10nAria));
  });
  root.querySelectorAll("[data-l10n-placeholder]").forEach((element) => {
    element.setAttribute("placeholder", t(element.dataset.l10nPlaceholder));
  });
  root.querySelectorAll("[data-l10n-title]").forEach((element) => {
    element.setAttribute("title", t(element.dataset.l10nTitle));
  });
  const title = document.querySelector("title[data-l10n]");
  if (title) document.title = t(title.dataset.l10n);
}

export async function loadCatalog() {
  choice = pick();
  document.documentElement.lang = choice.language;
  if (choice.language !== "zh-Hans") {
    try {
      const response = await fetch(new URL("./l10n.json", import.meta.url));
      if (response.ok) catalog = await response.json();
    } catch {
      // The page stays Simplified Chinese, the same as a missing translation.
    }
  }
  applyDocument();
  document.documentElement.hidden = false;
}

export const testing = { parse, LOCALES };
