# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WaifuX is a native macOS application built with Swift 6.0 and SwiftUI, targeting macOS 14.0+. It aggregates ACG content: static wallpapers (Wallhaven / 4K Wallpapers), dynamic wallpapers, and anime videos via a rule-based parser engine.

## Build System & Dependencies

**XcodeGen + Manual SPM**: The project uses `project.yml` with XcodeGen to generate `WaifuX.xcodeproj`, but **Kingfisher is added manually via SPM in the Xcode project and is NOT declared in `project.yml`**. Running `xcodegen generate` will remove the Kingfisher dependency and break the build. If you must regenerate the project, re-add Kingfisher via Xcode's SPM integration afterwards.

**Dependencies**:
- SwiftSoup (HTML parsing)
- Kanna (XPath)
- Kingfisher (image loading, manually managed in xcodeproj)

**Common Commands**:
- Open in Xcode: `open WaifuX.xcodeproj`
- Regenerate project (DANGER — see above): `xcodegen generate`
- CI build (unsigned): `xcodebuild -project WaifuX.xcodeproj -scheme WaifuX -destination 'platform=macOS' -configuration Release -derivedDataPath build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO clean build`
- Package DMG locally: `./scripts/package.sh`

**Version Management**: The single source of truth is the `VERSION` file. CI automatically injects it into `project.yml`'s `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` during builds.

## Architecture

**Custom App Lifecycle**: `App/WaifuXApp.swift` does not use `App`/`Scene`. It bootstraps an `NSApplication` manually with a custom `AppDelegate` that creates an `NSWindow` hosting SwiftUI via `EdgeToEdgeHostingView`. The app hides the system traffic lights and uses a custom `CustomWindowControls` component.

**Layer Structure**:
- `App/` — Entry point, `AppDelegate`, window management, Kingfisher configuration
- `Views/` — SwiftUI views. `ContentView.swift` is the root shell; it uses a `ZStack` with `opacity` to cache all 5 main tabs (`HomeContentView`, `WallpaperExploreContentView`, `AnimeExploreView`, `MediaExploreContentView`, `MyLibraryContentView`) instead of recreating them on tab switches
- `ViewModels/` — `ObservableObject` view models (e.g., `WallpaperViewModel`, `AnimeViewModel`, `MediaExploreViewModel`)
- `Models/` — Data models (`Wallpaper`, `MediaItem`, `AnimeRule`, etc.)
- `Services/` — Core business logic actors and singletons
- `Components/` — Reusable SwiftUI components
- `DesignSystem/` — Custom Liquid Glass design tokens and controls
- `Utilities/` — Helpers (`ImageLoader`, `AppLogger`, `GitHubHosts`, etc.)

**Critical Services**:
- `NetworkService` (actor) — Central async networking with retry logic and GitHub hosts acceleration
- `ImageLoader` (actor) — Custom NSCache + disk image loader with ImageIO downsampling; works alongside Kingfisher
- `WallpaperSourceManager` (@MainActor singleton) — Manages dual-source failover between Wallhaven and 4KWallpapers with health checks
- `AnimeParser` (actor) — Multi-source anime scraping engine that consumes `AnimeRule` definitions
- `KazumiRuleLoader` / `AnimeRuleStore` — Loads and caches Kazumi-format rules from remote repositories
- `AppLogger` (@MainActor) — Structured logging to both os.log and `~/Library/Application Support/WaifuX/waifux.log`

## Rule Engine

The app separates scraping logic from the client via dynamic rules:

- **Wallpaper / Media rules**: `Services/RuleLoader.swift` loads JSON rules into `DataSourceRule` models, stored in `~/Library/Application Support/WallHaven/Rules`
- **Anime rules**: `Services/KazumiRuleLoader.swift` fetches Kazumi-format rules from `https://github.com/Predidit/KazumiRules` and converts them to internal `AnimeRule` models
- `AnimeRules/` is a bundled folder reference (empty at build time) used for runtime rule installation

## Critical macOS Constraints

**DO NOT read `UserDefaults.standard` in any singleton `init()`**. On macOS 26+, this triggers a `_CFXPreferences` implicit recursion that causes an `EXC_BAD_ACCESS` SIGSEGV stack-overflow crash (174K frames deep). All state restoration is deferred to `AppDelegate.restoreAllDataAsync()` and performed in staggered `DispatchQueue.main.async` blocks after `applicationDidFinishLaunching`.

If you add new singletons that persist state:
1. Do NOT read `UserDefaults` in `init()`
2. Provide a `restoreSavedData()` / `restoreState()` method
3. Call it from `AppDelegate.restoreAllDataAsync()` in an appropriate frame

## Window & Lifecycle Behavior

- Closing the main window does **not** terminate the app (`applicationShouldTerminateAfterLastWindowClosed` returns `false`)
- The app can run without a Dock icon (`activationPolicy` toggles between `.regular` and `.accessory`)
- The settings window is created via `AppDelegate.showSettingsWindow(_:)` as a separate fixed-size panel

## Testing

There are currently no unit tests in this repository.

## CI / CD

- `.github/workflows/ci.yml` — Builds and releases a DMG on pushes to `feature/wallpaper-engine` when `VERSION` changes
- `.github/workflows/release.yml` — Drafts a release on tag push (`v*`)
- Both require the `macos-26` runner and Xcode 26.4
