#!/usr/bin/env python3
"""Validate catalog coverage/format tokens and exercise localization without app side effects.

Run from any directory: python3 scripts/verify-spanish-localization.py
Requires the macOS Swift toolchain; preferences are replaced with an in-memory stub.
"""
import json
from pathlib import Path
import re
import subprocess
import tempfile
from collections import Counter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Services/LocalizationService.swift"
text = SOURCE.read_text()
entry_pattern = r'^\s*"((?:[^"\\]|\\.)*)": "((?:[^"\\]|\\.)*)",?\s*$'
tables = {}
for language, body in re.findall(
    r'\.(spanish|english|chinese|japanese): \[(.*?)(?=\n\s*\.(?:spanish|english|chinese|japanese): \[|\n\s*\]\n\s*\])',
    text, re.S,
):
    entries = re.findall(entry_pattern, body, re.M)
    duplicates = [key for key, count in Counter(k for k, _ in entries).items() if count > 1]
    assert not duplicates, (language, duplicates)
    tables[language] = dict(entries)
assert set(tables) == {"spanish", "english", "chinese", "japanese"}
assert tables["english"].keys() <= tables["spanish"].keys(), "Missing Spanish keys"
tokens = re.compile(r'%(?:\d+\$)?[-+0 #]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp%]|\{[^{}]+\}')
for key, english in tables["english"].items():
    assert tokens.findall(english) == tokens.findall(tables["spanish"][key]), key
for key, spanish in tables["spanish"].items():
    assert spanish.strip(), key
    assert not re.search(r'[\u4e00-\u9fff]', spanish), (key, spanish)
    if re.search(r'[\u4e00-\u9fff]', key):
        assert tokens.findall(key) == tokens.findall(spanish), key

# Literal app lookups must not expose an untranslated identifier in Spanish.
for folder in ["App", "Views", "Components", "Models", "ViewModels", "Services", "BackgroundAgent", "Utilities"]:
    for source in (ROOT / folder).rglob("*.swift"):
        if source == SOURCE:
            continue
        for key in re.findall(r'\bt\("((?:[^"\\]|\\.)*)"\)', source.read_text()):
            if "\\(" not in key:
                assert key in tables["spanish"], (source, key)

# Test actual Swift lookup, persistence, notification, locale detection and HTML escaping.
# Never link the app/helper or use the real preference domain.
harness = r'''
import Foundation
final class WaifuXPreferences {
    static let shared = WaifuXPreferences()
    private var values: [String: String] = [:]
    func set(_ value: String, forKey key: String) { values[key] = value }
    func string(forKey key: String) -> String? { values[key] }
}
let localization = LocalizationService.shared
assert(localization.currentLanguage == .spanish, "Spanish system locale not detected")
assert(LocalizationService.Language.allCases.contains(.spanish))
assert(LocalizationService.Language.spanish.displayName == "Español (España)")
var notified = false
let observer = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: nil) { _ in notified = true }
localization.setLanguage(.english)
assert(notified)
assert(t("nav.home") == "HOME")
WaifuXPreferences.shared.set("es", forKey: "app_language")
localization.restoreSavedSettings()
assert(localization.currentLanguage == .spanish)
assert(t("nav.home") == "INICIO")
assert(AnimeHotTag.daily.apiTagName == "日常")
assert(AnimeHotTag.lightNovel.apiTagName == "轻小说改")
assert(WallpaperEnginePropertyLocalizer.label(for: "ui_browse_properties_brightness") == "Brillo")
assert(WallpaperEnginePropertyLocalizer.label(for: "background") == "Fondo")
assert(WaifuXPreferences.shared.string(forKey: "app_language") == "es")
assert(t("unknown.test.key") == "unknown.test.key")
assert(String(format: t("repairResult"), 1, 2, 3, 4, 5).contains("reparados: 2"))
assert(String(format: t("downloads.batchResult"), 2, 1).contains("Correctas: 2"))
assert(localization.legacyLabel("亮度") == "Brillo")
let editor = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let translated = localization.localizedEditorHTML(editor)
assert(translated.contains("lang=\"es-ES\""))
assert(!translated.contains("设计场景"))
assert(!translated.contains("赞赏支持"))
assert(!translated.contains("没有可编辑的动态文本元素"))
assert(translated.contains("notifyDesignChange(entry.id, 'hidden', val)"))
let saverSource = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
assert(!saverSource.isEmpty)
assert(SaverLocalization.string("missingMedia", language: "es-ES").contains("Falta el archivo"))
assert(SaverLocalization.string("missingMedia", language: "es-MX").contains("Falta el archivo"))
assert(SaverLocalization.string("missingMedia", language: "en").contains("missing"))
localization.setLanguage(.japanese)
assert(t("nav.home") == "ホーム")
assert(t("episode.number") == "Episode %d")
assert(localization.localizedEditorHTML(editor) == editor)
localization.setLanguage(.chinese)
assert(t("nav.home") == "首页")
NotificationCenter.default.removeObserver(observer)
try translated.write(toFile: CommandLine.arguments[3], atomically: true, encoding: .utf8)
print("LOCALIZATION_RUNTIME_PASSED")
'''
with tempfile.TemporaryDirectory(prefix="waifux-localization-") as directory:
    temp = Path(directory)
    (temp / "main.swift").write_text(harness)
    hot_tags = (ROOT / "ViewModels/AnimeViewModel.swift").read_text()
    (temp / "AnimeHotTag.swift").write_text("import Foundation\n" + hot_tags[hot_tags.index("enum AnimeHotTag:"):])
    properties = (ROOT / "Services/SceneWallpaperPropertiesService.swift").read_text()
    localizer = properties[properties.index("enum WallpaperEnginePropertyLocalizer {"):properties.index("/// 属性展示方式")]
    (temp / "PropertyLocalizer.swift").write_text("import Foundation\nstruct WaifuXHostBundle { static func resourceCandidates(named: String) -> [URL] { [] } }\n" + localizer)
    saver = (ROOT / "WaifuXScreenSaver/SaverConfiguration.swift").read_text()
    (temp / "SaverLocalization.swift").write_text("import Foundation\n" + saver[saver.index("enum SaverLocalization {"):])
    subprocess.run(["swiftc", str(SOURCE), str(temp / "SaverLocalization.swift"), str(temp / "AnimeHotTag.swift"), str(temp / "PropertyLocalizer.swift"), str(temp / "main.swift"), "-o", str(temp / "check")], check=True)
    for locale in ["es-ES", "es-MX", "es"]:
        subprocess.run([str(temp / "check"), str(ROOT / "Resources/WallpaperPropertyEditor.html"), str(ROOT / "WaifuXScreenSaver/SaverConfiguration.swift"), str(temp / "editor.html"), "-AppleLanguages", f"({locale})"], check=True)
    # If Node is available, parse the exact localized JavaScript emitted by Swift.
    import shutil
    if shutil.which("node"):
        html = (temp / "editor.html").read_text()
        (temp / "editor.js").write_text("\n".join(re.findall(r'<script>(.*?)</script>', html, re.S)))
        subprocess.run(["node", "--check", str(temp / "editor.js")], check=True)
print(f"SPANISH_LOCALIZATION_PASSED english={len(tables['english'])} spanish={len(tables['spanish'])}")
