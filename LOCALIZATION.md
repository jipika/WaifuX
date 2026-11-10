# App localization

The interface uses `LocalizationService` and its `t(_:)` lookup. Supported languages are Simplified Chinese, English, Japanese and Spanish (Spain). Choose Spanish in Settings → General → Language; it applies immediately. A system language beginning with `es` also selects the Spanish translation on first launch.

## Adding or updating strings

- Add a semantic key to the English catalog and translate it in the Spanish catalog. Preserve format tokens (`%@`, `%d`, `%%`) and named placeholders (`{number}`, `{count}`) exactly.
- Legacy Chinese literals that previously bypassed localization use their original text as a lookup key. This preserves their existing fallback in other languages. New English keys fall back to English when a language does not yet supply them.
- Keep API tags, stored enum raw values, paths, protocol messages and user/author-provided wallpaper content independent of the interface language.
- The property editor bridges its bundled Chinese labels through the same catalog. Author-provided property localization prefers the selected app language, including `es-es`, when the wallpaper supplies it.
- The standalone screen saver has a small separate `SaverLocalization` table and localized bundle names. The app's permission descriptions live in `App/es.lproj/InfoPlist.strings`.

## Validation

Run `python3 scripts/verify-spanish-localization.py` on macOS with the Swift toolchain. It checks catalog coverage, duplicate keys and format placeholders, then compiles the actual localization service against in-memory preferences. It exercises locale detection, preference restoration, change notifications, language switching, fallback behavior, screen saver messages and property-editor translation. When Node is available, it also checks the resulting JavaScript syntax. It does not start WaifuX, register its helper, alter wallpapers or write app preferences.

Build all targets with:

```sh
xcodebuild -project WaifuX.xcodeproj -scheme WaifuX -configuration Debug -derivedDataPath /tmp/WaifuX-localization-build CODE_SIGNING_ALLOWED=NO build
```

System permission dialogs follow the language selected for the app by macOS; the in-app language picker cannot override the operating system's dialog language. Third-party catalog titles, subtitles and wallpaper-authored content retain their source text unless the source supplies a Spanish translation.
