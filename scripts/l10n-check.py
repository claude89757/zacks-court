#!/usr/bin/env python3
"""Catalog check for the six in-app languages, and the one-shot Swift/JS wrapper.

Simplified Chinese strings are the catalog keys. `courtText` / `t()` return the key unchanged
for zh-Hans. This script does not publish anything and does not talk to App Store Connect.

    python3 scripts/l10n-check.py            # coverage: exit 1 when a user-visible string is missing
    python3 scripts/l10n-check.py --self-test
    python3 scripts/l10n-check.py --wrap     # rewrite call sites once; review the diff

Coverage walks Sources for Chinese literals that are not passed to courtText / courtFormat /
courtPrintf / t / fmt, and are not exempt (engine match keys, dictionary keys, comparison
arguments). Every catalog entry needs zh-Hant, en, ja, de and fr, with the same placeholders.
A translation that copies the Simplified Chinese source has to be listed under "unchanged".
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "Sources/CourtCore/Web/l10n.json"
LOCALES = ["zh-Hant", "en", "ja", "de", "fr"]
SKIP_FILES = {
    "CourtCopy.swift",
    # Stroke names here are stored tokens ("发球"), not copy. Translating the comparison
    # would stop serve speeds from being recognised in any language but Simplified Chinese.
    "IndependentShotPipeline.swift",
    # The demo record is always written in Simplified Chinese. Screens translate it on display.
    "DemoSession.swift",
}
# Engine wording matched by TennisReason.classify and similar. Not shown as the short reason.
EXEMPT_EXACT = {
    "等待",
    "触地定位失败",
}


def scan_swift(text: str):
    """Yield (start, end, kind, payload) for each Chinese string literal.

    kind is 'plain', 'interp', or 'printf' (the format string of String(format:)).
    payload for plain is the decoded string. For interp it is (format_key, [expr, ...])
    where exprs are source snippets including the surrounding interpolation.
    start/end cover the literal including quotes, or the whole String(format: call's format
    token for printf (the literal only; the caller rewrites the callee).
    """
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            i = text.find("\n", i)
            i = n if i < 0 else i
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if text[i] != '"':
            i += 1
            continue
        start = i
        parts, exprs, interp = read_string(text, i)
        i = parts  # reused: read_string returns (end_index, chunks, exprs, interp) — fix below
        # placeholder to keep the type checker quiet; real return is unpacked in read_string
        yield start  # pragma: no cover


def read_string(text, i):
    """i points at the opening quote. Returns (end_after_quote, literal, interp, exprs)."""
    assert text[i] == '"'
    i += 1
    buf = []
    exprs = []
    interp = False
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n and text[i + 1] == "(":
            interp = True
            i += 2
            expr, i = read_interpolation(text, i)
            exprs.append(expr)
            buf.append(f"%{len(exprs)}$@")
            continue
        if c == "\\":
            buf.append(text[i + 1] if i + 1 < n else "")
            i += 2
            continue
        if c == '"':
            return i + 1, "".join(buf), interp, exprs
        buf.append(c)
        i += 1
    return n, "".join(buf), interp, exprs


def read_interpolation(text, i):
    """i is just after \\(. Returns (expr_source, index_after_closing_paren)."""
    start = i
    depth = 1
    n = len(text)
    while i < n and depth:
        if text[i] == '"':
            end, _, _, _ = read_string(text, i)
            i = end
            continue
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start:i], i + 1
        i += 1
    return text[start:i], i


def has_cjk(s: str) -> bool:
    return bool(re.search(r"[\u4e00-\u9fff]", s))


def callee_name(text, quote_start):
    """Identifier of the call whose first argument is this literal, if any."""
    j = quote_start
    while j > 0 and text[j - 1] in " \t\n":
        j -= 1
    if j > 0 and text[j - 1] == "(":
        j -= 1
        while j > 0 and text[j - 1] in " \t\n":
            j -= 1
    k = j
    while k > 0 and (text[k - 1].isalnum() or text[k - 1] == "_"):
        k -= 1
    return text[k:j]


def previous_ident(text, index):
    return callee_name(text, index)


def next_nonspace(text, index):
    n = len(text)
    while index < n and text[index] in " \t\n":
        index += 1
    return text[index] if index < n else ""


def is_wrapped(text, start):
    ident = previous_ident(text, start)
    return ident in {"courtText", "courtFormat", "courtPrintf", "t", "fmt"}


def is_comparison(text, start):
    if previous_ident(text, start) in {"contains", "hasPrefix", "hasSuffix", "startsWith"}:
        return True
    j = start
    while j > 0 and text[j - 1] in " \t\n":
        j -= 1
    return text[max(0, j - 2) : j] in {"==", "!="}


def is_dictionary_key(text, opening, end):
    """A literal followed by `:` is a key only inside a collection, not the `? a : b` form."""
    if next_nonspace(text, end) != ":":
        return False
    j = opening
    while j > 0 and text[j - 1] in " \t\n":
        j -= 1
    return j > 0 and text[j - 1] in "[{,"


def is_printf_format(text, start):
    """The literal is the first argument of String(format:)."""
    j = start
    while j > 0 and text[j - 1] in " \t\n":
        j -= 1
    if j < len("format:") or text[j - len("format:") : j] != "format:":
        return False
    head = text[: j - len("format:")]
    return head.rstrip().endswith("String(")


def rewrite_swift(text: str):
    """Return rewritten source. Only Chinese literals that are shown, not match keys."""
    spans = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            nl = text.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if text[i] != '"':
            i += 1
            continue
        end, literal, interp, exprs = read_string(text, i)
        line_start = text.rfind("\n", 0, i) + 1
        line_end = text.find("\n", end)
        if line_end < 0:
            line_end = n
        kept = "l10n:keep" in text[line_start:line_end]
        if has_cjk(literal) and literal not in EXEMPT_EXACT and not is_wrapped(text, i) and not is_comparison(text, i) and not kept:
            if is_dictionary_key(text, i, end):
                i = end
                continue
            if is_printf_format(text, i):
                # Replace `String(format:` immediately before this literal with `courtPrintf(`.
                j = i
                while j > 0 and text[j - 1] in " \t\n":
                    j -= 1
                fmt_key = text.rfind("format:", 0, j)
                string_at = text.rfind("String(", 0, fmt_key)
                if string_at >= 0:
                    end_call = fmt_key + len("format:")
                    while end_call < i and text[end_call] in " \t\n":
                        end_call += 1
                    spans.append((string_at, end_call, "printf-call", None))
                spans.append((i, end, "keep", literal))
            elif interp:
                args = ", ".join(f'"\\({expr})"' for expr in exprs)
                # The exprs were captured without the \\( ) wrapper; rebuild call.
                args = ", ".join(string_interpolation(expr) for expr in exprs)
                replacement = f'courtFormat("{escape_swift(literal)}", {args})'
                spans.append((i, end, "replace", replacement))
            else:
                spans.append((i, end, "replace", f'courtText("{escape_swift(literal)}")'))
        i = end
    out = []
    cursor = 0
    for start, end, kind, payload in spans:
        out.append(text[cursor:start])
        if kind == "printf-call":
            out.append("courtPrintf(")
        elif kind == "replace":
            out.append(payload)
        else:
            out.append(text[start:end])
        cursor = end
    out.append(text[cursor:])
    return "".join(out)


def string_interpolation(expr: str) -> str:
    return '"\\(' + expr + ')"'


def escape_swift(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def skip_regex(text, i):
    """If `i` points at a regex literal, return the index after it. Division returns None."""
    if text[i] != "/":
        return None
    if i + 1 < len(text) and text[i + 1] in "/*":
        return None
    j = i - 1
    while j >= 0 and text[j] in " \t":
        j -= 1
    if j >= 0 and text[j] not in "=(,[{:!&|?;\n":
        return None
    k = i + 1
    n = len(text)
    while k < n and text[k] != "\n":
        if text[k] == "\\":
            k += 2
            continue
        if text[k] == "[":
            k += 1
            while k < n and text[k] not in "]\n":
                k += 2 if text[k] == "\\" else 1
            k += 1
            continue
        if text[k] == "/":
            k += 1
            while k < n and text[k].isalpha():
                k += 1
            return k
        k += 1
    return None


def rewrite_js(text: str):
    """Wrap Chinese string literals and template literals in t() / fmt(). Skip l10n.js."""
    out = []
    i, n = 0, len(text)
    while i < n:
        regex_end = skip_regex(text, i)
        if regex_end is not None:
            out.append(text[i:regex_end])
            i = regex_end
            continue
        if text.startswith("//", i):
            nl = text.find("\n", i)
            end = n if nl < 0 else nl
            out.append(text[i:end])
            i = end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(text[i:end])
            i = end
            continue
        if text[i] in "'\"":
            quote = text[i]
            end, literal = read_js_string(text, i, quote)
            if (
                has_cjk(literal)
                and not is_wrapped(text, i)
                and not is_comparison(text, i)
                and not is_dictionary_key(text, i, end)
            ):
                out.append(f't("{escape_js(literal)}")')
            else:
                out.append(text[i:end])
            i = end
            continue
        if text[i] == "`":
            end, key, exprs = read_template(text, i)
            if has_cjk(key) and not is_wrapped(text, i):
                args = ", ".join(exprs)
                out.append(f'fmt("{escape_js(key)}", {args})')
            else:
                out.append(text[i:end])
            i = end
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def read_js_string(text, i, quote):
    i += 1
    buf = []
    n = len(text)
    while i < n:
        if text[i] == "\\":
            buf.append(text[i + 1] if i + 1 < n else "")
            i += 2
            continue
        if text[i] == quote:
            return i + 1, "".join(buf)
        buf.append(text[i])
        i += 1
    return n, "".join(buf)


def read_template(text, i):
    """Return (end, key_with_placeholders, [expr, ...])."""
    i += 1
    buf = []
    exprs = []
    n = len(text)
    while i < n:
        if text.startswith("${", i):
            i += 2
            expr, i = read_js_expr(text, i)
            exprs.append(expr)
            buf.append(f"%{len(exprs)}$@")
            continue
        if text[i] == "\\":
            buf.append(text[i + 1] if i + 1 < n else "")
            i += 2
            continue
        if text[i] == "`":
            return i + 1, "".join(buf), exprs
        buf.append(text[i])
        i += 1
    return n, "".join(buf), exprs


def read_js_expr(text, i):
    depth = 1
    start = i
    n = len(text)
    while i < n and depth:
        if text[i] in "'\"":
            end, _ = read_js_string(text, i, text[i])
            i = end
            continue
        if text[i] == "`":
            end, _, _ = read_template(text, i)
            i = end
            continue
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i], i + 1
        i += 1
    return text[start:i], i


def escape_js(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def swift_files():
    for path in (ROOT / "Sources").rglob("*.swift"):
        if path.name in SKIP_FILES:
            continue
        if "Tests" in path.parts:
            continue
        yield path


def js_files():
    web = ROOT / "Sources/CourtCore/Web"
    for name in ("app.js", "index.html"):
        path = web / name
        if path.exists():
            yield path


def collect_keys_from_source():
    keys = set()
    for path in list(swift_files()) + [p for p in js_files() if p.suffix == ".js"]:
        text = path.read_text(encoding="utf-8")
        if path.suffix == ".swift":
            i, n = 0, len(text)
            while i < n:
                if text.startswith("//", i):
                    nl = text.find("\n", i)
                    i = n if nl < 0 else nl
                    continue
                if text.startswith("/*", i):
                    end = text.find("*/", i + 2)
                    i = n if end < 0 else end + 2
                    continue
                if text[i] != '"':
                    i += 1
                    continue
                end, literal, _, _ = read_string(text, i)
                if has_cjk(literal) and is_wrapped(text, i):
                    keys.add(literal)
                i = end
        else:
            i, n = 0, len(text)
            while i < n:
                if text.startswith("//", i):
                    nl = text.find("\n", i)
                    i = n if nl < 0 else nl
                    continue
                if text[i] in "'\"":
                    end, literal = read_js_string(text, i, text[i])
                    if has_cjk(literal) and is_wrapped(text, i):
                        keys.add(literal)
                    i = end
                    continue
                if text[i] == "`":
                    end, key, _ = read_template(text, i)
                    if has_cjk(key) and is_wrapped(text, i):
                        keys.add(key)
                    i = end
                    continue
                i += 1
    return keys


def unwrapped_chinese():
    """Chinese literals still sitting in UI source, outside wrappers and exemptions."""
    found = []
    for path in swift_files():
        text = path.read_text(encoding="utf-8")
        i, n = 0, len(text)
        line = 1
        while i < n:
            if text[i] == "\n":
                line += 1
                i += 1
                continue
            if text.startswith("//", i):
                nl = text.find("\n", i)
                i = n if nl < 0 else nl
                continue
            if text.startswith("/*", i):
                end = text.find("*/", i + 2)
                while i < (n if end < 0 else end):
                    if text[i] == "\n":
                        line += 1
                    i += 1
                i = n if end < 0 else end + 2
                continue
            if text[i] != '"':
                i += 1
                continue
            end, literal, _, _ = read_string(text, i)
            line_start = text.rfind("\n", 0, i) + 1
            line_end = text.find("\n", i)
            if line_end < 0:
                line_end = n
            if "l10n:keep" in text[line_start:line_end]:
                i = end
                continue
            if (
                has_cjk(literal)
                and literal not in EXEMPT_EXACT
                and not is_wrapped(text, i)
                and not is_comparison(text, i)
                and not is_dictionary_key(text, i, end)
            ):
                found.append(f"{path.relative_to(ROOT)}:{line}: {literal[:80]}")
            i = end
    return found


def placeholders(s: str):
    """Positional %@ (%1$@) and printf tokens, as a multiset of canonical forms."""
    tokens = []
    for match in re.finditer(r"%(?:(\d+)\$)?([0-9]*\.?[0-9]*[@a-zA-Z])", s):
        index, spec = match.group(1), match.group(2)
        tokens.append((int(index) if index else None, spec))
    # Assign order indices to non-positional tokens, left to right.
    auto = 1
    out = []
    for index, spec in tokens:
        if index is None:
            index = auto
            auto += 1
        else:
            auto = max(auto, index + 1)
        out.append(f"{index}:{spec}")
    return sorted(out)


def check_catalog(catalog, keys):
    errors = []
    strings = catalog.get("strings", {})
    unchanged = set(catalog.get("unchanged", []))
    missing_keys = sorted(keys - set(strings))
    for key in missing_keys:
        errors.append(f"missing catalog entry: {key[:80]}")
    extra = sorted(set(strings) - keys)
    # Extra entries are allowed (Info.plist and HTML copy share the catalog) but must be complete.
    for key, row in strings.items():
        if not isinstance(row, dict):
            errors.append(f"entry is not an object: {key[:40]}")
            continue
        for locale in LOCALES:
            value = row.get(locale)
            if not value:
                errors.append(f"{locale} empty: {key[:60]}")
                continue
            # Traditional Chinese and Japanese share many characters with the source.
            # English, German and French must be real translations.
            if locale in {"en", "de", "fr"} and value == key and key not in unchanged:
                errors.append(f"{locale} copies the source (add to unchanged or translate): {key[:60]}")
            if placeholders(value) != placeholders(key):
                errors.append(
                    f"{locale} placeholders {placeholders(value)} != {placeholders(key)} for {key[:50]}"
                )
        if re.search(r"Hawk-Eye|鹰眼|雷达|umpire|referee", " ".join(row.values()), re.I):
            errors.append(f"forbidden wording: {key[:60]}")
    return errors, extra


def load_catalog():
    if not CATALOG_PATH.exists():
        return {"strings": {}, "unchanged": []}
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def self_test():
    sample = '''
    Text("历史记录")
    Text("第 \\(number) 拍")
    if title.contains("演示数据") {}
    let table = ["等待首弹": .pending]
    flag ? "暂停" : "继续"
    String(format: "机高约 %.1f 米", h)
    courtText("已经包过")
    '''
    # The source above escaped backslash once for this file's string. Build the real Swift.
    sample = sample.replace("\\\\(", "\\(")
    rewritten = rewrite_swift(sample)
    checks = [
        'courtText("历史记录")' in rewritten,
        'courtFormat("第 %1$@ 拍"' in rewritten,
        'contains("演示数据")' in rewritten,
        '["等待首弹": .pending]' in rewritten,
        'courtText("暂停")' in rewritten and 'courtText("继续")' in rewritten,
        'courtPrintf("机高约 %.1f 米"' in rewritten,
        rewritten.count('courtText("已经包过")') == 1,
    ]
    js = rewrite_js('const a = "开始记录"; const b = `第 ${n} 拍`; const c = { active: "进行中" };')
    checks.append('t("开始记录")' in js)
    checks.append('fmt("第 %1$@ 拍", n)' in js)
    checks.append('t("进行中")' in js)
    assert placeholders("约 %1$@ 厘米") == placeholders("about %1$@ cm"), placeholders("约 %1$@ 厘米")
    assert placeholders("机高约 %.1f 米") == placeholders("about %.1f m")
    if not all(checks):
        print(rewritten)
        print(js)
        print(checks)
        raise SystemExit("self-test failed")
    print("l10n-check self-test passed")


def wrap_tree():
    changed = 0
    for path in swift_files():
        original = path.read_text(encoding="utf-8")
        updated = rewrite_swift(original)
        if updated != original:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    for path in js_files():
        if path.suffix != ".js":
            continue
        original = path.read_text(encoding="utf-8")
        updated = rewrite_js(original)
        if updated != original:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    print(f"rewrote {changed} files")


def main(argv):
    if "--self-test" in argv:
        self_test()
        return
    if "--wrap" in argv:
        wrap_tree()
        return
    catalog = load_catalog()
    keys = collect_keys_from_source()
    # Info.plist usage strings are catalog keys too when present.
    for entry in catalog.get("plist", []):
        keys.add(entry)
    errors, extra = check_catalog(catalog, keys)
    bare = unwrapped_chinese()
    if bare:
        errors.append(f"{len(bare)} Chinese literals are not wrapped (first 30):")
        errors.extend(bare[:30])
    if errors:
        print(f"{len(errors)} localization problems")
        for line in errors[:80]:
            print(line)
        if len(errors) > 80:
            print(f"... {len(errors) - 80} more")
        raise SystemExit(1)
    print(f"l10n catalog ok: {len(catalog.get('strings', {}))} entries, {len(keys)} source keys, {len(extra)} extra")


if __name__ == "__main__":
    main(sys.argv[1:])
