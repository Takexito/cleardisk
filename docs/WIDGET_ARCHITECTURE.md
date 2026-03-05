# ClearDisk macOS Desktop Widget — Architecture & Implementation Plan

## 1. Overview

macOS Desktop Widget (WidgetKit) for ClearDisk, displaying real-time information about:
- Remaining free disk space (absolute + percentage)
- Cache sizes by category (developer caches, project artifacts)
- Visual indicators of disk health (color-coded thresholds)

**Target:** macOS 14+ (Sonoma), WidgetKit
**Widget Families:** `.systemSmall`, `.systemMedium`, `.systemLarge`

---

## 2. Architectural Challenges & Solutions

### 2.1 SPM vs Xcode Project

**Problem:** The current project is pure SPM (`Package.swift`). WidgetKit extensions require an Xcode project with embedded targets — SPM does not support app extensions natively.

**Solution (Canonical):** Create a single `.xcodeproj` that wraps the existing SPM structure:
- The main app becomes an App target that depends on SPM packages
- The widget becomes a Widget Extension target **embedded in the main app bundle**
- Shared code (`Sources/Shared/`) is a local Swift Package imported by both targets
- This is the standard Apple-recommended approach for app + extension bundles

**Alternative (trade-offs documented):** Keep SPM for the main app and create a standalone companion Xcode project only for the widget. This avoids touching the existing build pipeline but introduces complexity: two separate build artifacts, independent signing, and the widget `.appex` must be manually copied into the app bundle during a post-build step. Not recommended unless the main app cannot migrate to an Xcode project wrapper for other reasons.

### 2.2 Data Sharing Between App & Widget

**Problem:** The widget runs in a separate process. Widget Extensions are **always sandboxed** by macOS regardless of whether the host app is sandboxed or not. The extension cannot access arbitrary filesystem paths or `DiskMonitor`'s in-memory state.

**Solution:** Use **App Groups** as the sole data-sharing mechanism. Both the main app and the widget extension must be signed with the same Team ID and configured with the same App Group entitlement. This is a hard requirement — there is no fallback.

```
App Group: group.com.cleardisk.shared
├── shared UserDefaults(suiteName:) for lightweight metrics (used %, free space)
└── shared container file: widget-data.json (full cache breakdown)
```

**Signing requirement:** Both the main app and the widget extension must be code-signed (at minimum with a Developer ID or local development certificate) and include the `com.apple.security.application-groups` entitlement pointing to `group.com.cleardisk.shared`. Unsigned builds will not have access to App Group containers.

**Entitlements files needed:**
- `ClearDisk.entitlements` — for the main app
- `ClearDiskWidget.entitlements` — for the widget extension

Both contain:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.cleardisk.shared</string>
</array>
```

### 2.3 Widget Timeline & Freshness

WidgetKit widgets are **not live-updating** — they use a `TimelineProvider` that returns snapshots at scheduled intervals.

**Strategy:**
- Main app writes fresh data after every scan (every 5 minutes)
- Widget timeline: reload every 15 minutes (WidgetKit minimum reasonable interval)
- Main app calls `WidgetCenter.shared.reloadAllTimelines()` after each scan to force widget refresh

---

## 3. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    ClearDisk Main App                        │
│                                                             │
│  ┌──────────────┐    ┌───────────────┐    ┌──────────────┐ │
│  │ DiskMonitor   │───▶│ WidgetDataWriter│───▶│ App Group    │ │
│  │ (scan every   │    │ (serialize to  │    │ Container    │ │
│  │  5 min)       │    │  JSON + notify)│    │              │ │
│  └──────────────┘    └───────────────┘    └──────┬───────┘ │
│                                                   │         │
│  After scan: WidgetCenter.shared.reloadTimelines()│         │
└───────────────────────────────────────────────────┼─────────┘
                                                    │
                              ┌──────────────────────┘
                              │ Shared File / UserDefaults
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 ClearDisk Widget Extension                   │
│                                                             │
│  ┌──────────────┐    ┌───────────────┐    ┌──────────────┐ │
│  │TimelineProvider│───▶│WidgetDataReader│───▶│  Widget Views │ │
│  │ (read shared  │    │ (deserialize   │    │  Small/Med/  │ │
│  │  data)        │    │  JSON)         │    │  Large       │ │
│  └──────────────┘    └───────────────┘    └──────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. Shared Data Model

### 4.1 `WidgetData` — Serializable struct written by app, read by widget

```swift
struct WidgetData: Codable {
    let timestamp: Date

    // Disk overview
    let totalSpaceBytes: Int64
    let freeSpaceBytes: Int64
    let usedSpaceBytes: Int64
    let usedPercentage: Int

    // Cache summary
    let totalCleanableBytes: Int64
    let safeCleanableBytes: Int64
    let riskyCleanableBytes: Int64

    // Top caches by size (for medium/large widget)
    let topCaches: [CacheSummary]

    // Forecast
    let forecastDaysUntilFull: Int?
    let dailyGrowthRateBytes: Int64

    // Savings
    let totalSavedAllTimeBytes: Int64
}

struct CacheSummary: Codable {
    let name: String        // e.g. "Xcode DerivedData"
    let sizeBytes: Int64
    let icon: String        // SF Symbol name
    let riskLevel: String   // "safe", "caution", "risky"
    let category: String    // "IDE", "Package Manager", etc.
}
```

### 4.2 Storage Location

The **only** production path for data exchange is the App Group container:

```
~/Library/Group Containers/group.com.cleardisk.shared/widget-data.json
```

This path is managed by macOS and accessible to both the main app and the widget extension when they share the `group.com.cleardisk.shared` App Group entitlement.

**There is no filesystem fallback.** Widget Extensions are always sandboxed and cannot read from `~/Library/Application Support/` or other arbitrary paths. App Groups + code signing are a hard requirement for this feature.

**Access pattern in code:**
```swift
import os

private let logger = Logger(subsystem: "com.cleardisk", category: "SharedPaths")

func widgetDataURL() -> URL? {
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.cleardisk.shared"
    ) else {
        logger.error("App Group container unavailable — check entitlements and code signing")
        return nil
    }
    return containerURL.appendingPathComponent("widget-data.json")
}
```

---

## 5. File Structure

```
Sources/
├── ClearDisk/                      # Existing main app
│   ├── ClearDiskApp.swift
│   ├── DiskMonitor.swift
│   ├── MainView.swift
│   └── WidgetDataWriter.swift      # NEW — writes shared data after scan
│
├── Shared/                         # NEW — shared models
│   ├── WidgetData.swift            # WidgetData + CacheSummary models
│   └── SharedPaths.swift           # App Group container path resolution
│
└── ClearDiskWidget/                # NEW — Widget Extension
    ├── ClearDiskWidget.swift       # Widget entry point + configuration
    ├── WidgetTimelineProvider.swift # TimelineProvider implementation
    ├── WidgetDataReader.swift      # Reads shared JSON from App Group container
    └── Views/
        ├── SmallWidgetView.swift   # .systemSmall layout
        ├── MediumWidgetView.swift  # .systemMedium layout
        └── LargeWidgetView.swift   # .systemLarge layout

Entitlements/
├── ClearDisk.entitlements          # NEW — App Group entitlement for main app
└── ClearDiskWidget.entitlements    # NEW — App Group entitlement for widget
```

---

## 6. Widget Layouts

### 6.1 Small Widget (`.systemSmall`) — Disk Health at a Glance

```
┌─────────────────────┐
│     ClearDisk       │
│                     │
│   ┌───────────┐    │
│   │           │    │
│   │  72%      │    │  ← Circular progress ring
│   │  used     │    │     Color: green/yellow/red
│   └───────────┘    │
│                     │
│  45.2 GB free      │  ← Free space label
│  12.8 GB cleanable │  ← Cleanable amount
└─────────────────────┘
```

### 6.2 Medium Widget (`.systemMedium`) — Disk + Top Caches

```
┌──────────────────────────────────────────┐
│  ClearDisk              45.2 GB free     │
│  ┌──────┐                                │
│  │ 72%  │  ■ Xcode DerivedData   4.2 GB │
│  │ used │  ■ Docker Images       3.8 GB │
│  └──────┘  ■ node_modules        2.1 GB │
│            ■ Homebrew Cache      1.5 GB │
│                                          │
│  Total cleanable: 12.8 GB    Open App ▸ │
└──────────────────────────────────────────┘
```

### 6.3 Large Widget (`.systemLarge`) — Full Dashboard

```
┌──────────────────────────────────────────┐
│  ClearDisk Storage Monitor               │
│                                          │
│  ┌──────────┐   Total: 500 GB           │
│  │          │   Used:  354.8 GB (72%)   │
│  │   72%    │   Free:  145.2 GB         │
│  │   used   │                            │
│  └──────────┘   ⚠ ~45 days until full   │
│                                          │
│  ── Developer Caches ──────── 8.6 GB ── │
│  🟢 Xcode DerivedData        4.2 GB    │
│  🟢 Homebrew Cache            1.5 GB    │
│  🟡 CocoaPods Cache           1.1 GB    │
│  🔴 Docker Images             1.8 GB    │
│                                          │
│  ── Project Artifacts ─────── 4.2 GB ── │
│  📁 node_modules (12 projects) 2.1 GB  │
│  📁 .build (5 projects)       1.3 GB   │
│  📁 target (3 projects)       0.8 GB   │
│                                          │
│  Total cleanable: 12.8 GB               │
│  Total saved all time: 156 GB           │
│                                          │
│            [ Open ClearDisk ]            │
└──────────────────────────────────────────┘
```

---

## 7. Implementation Plan — Step by Step

### Phase 1: Shared Data Layer (Foundation)

**Step 1.1** — Create `Sources/Shared/WidgetData.swift`
- Define `WidgetData` and `CacheSummary` as `Codable` structs
- Include all fields needed by all three widget sizes

**Step 1.2** — Create `Sources/Shared/SharedPaths.swift`
- Define App Group identifier constant: `group.com.cleardisk.shared`
- Resolve shared container via `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
- Shared file path: `<App Group Container>/widget-data.json`
- If container URL is `nil` (entitlements misconfigured or unsigned build):
  - Log a descriptive warning via `os.Logger` (not `fatalError` — never crash the host app for a config issue)
  - `WidgetDataWriter.write()` becomes a no-op, returns `false`
  - Optionally surface a non-blocking diagnostic in the app UI (e.g. "Widget data sharing unavailable — check code signing")
- Strict validation belongs in CI/build scripts: add a build phase that runs `codesign -d --entitlements :-` and asserts the App Group key is present

**Step 1.3** — Create `Sources/ClearDisk/WidgetDataWriter.swift`
- `WidgetDataWriter.write(from: DiskMonitor)` — serializes current state to JSON
- Picks top N caches sorted by size
- Writes atomically to shared path

**Step 1.4** — Integrate writer into `DiskMonitor.swift`
- After `scan()` completes, call `WidgetDataWriter.write(from: self)`
- Add `WidgetCenter.shared.reloadAllTimelines()` call (conditional import for WidgetKit)

### Phase 2: Widget Extension

**Step 2.1** — Create widget entry point `Sources/ClearDiskWidget/ClearDiskWidget.swift`
- Define `@main` widget bundle
- Support `.systemSmall`, `.systemMedium`, `.systemLarge`
- Configure display name and description

**Step 2.2** — Create `WidgetDataReader.swift`
- Read and decode `widget-data.json` from shared path
- Return default/placeholder data if file doesn't exist or is stale (>30 min)

**Step 2.3** — Create `WidgetTimelineProvider.swift`
- `placeholder()` — static mock data for widget gallery
- `getSnapshot()` — current data for widget preview
- `getTimeline()` — read shared data, create entry, set next reload in 15 min

**Step 2.4** — Implement `SmallWidgetView.swift`
- Circular progress ring (custom `Shape`)
- Free space label, cleanable label
- Color-coded by threshold (green < 80%, yellow 80-90%, red > 90%)

**Step 2.5** — Implement `MediumWidgetView.swift`
- Compact progress ring + top 4 caches list
- "Open App" deep link button

**Step 2.6** — Implement `LargeWidgetView.swift`
- Full dashboard: disk stats, forecast, categorized caches, project artifacts
- Risk level indicators (colored dots)
- "Open ClearDisk" deep link

### Phase 3: Build System & Signing

**Step 3.1** — Create Xcode project wrapping SPM (canonical approach per §2.1)
- Create a single `.xcodeproj` with two targets: main App and Widget Extension
- Widget Extension target is embedded in the main App target ("Embed App Extensions" build phase)
- Both targets depend on `Sources/Shared/` as a local Swift Package

**Step 3.2** — Update `Package.swift`
- Add a library target for shared code
- Keep executable target for main app

**Step 3.3** — Create entitlements files
- `Entitlements/ClearDisk.entitlements` — add `com.apple.security.application-groups` with `group.com.cleardisk.shared`
- `Entitlements/ClearDiskWidget.entitlements` — same App Group entitlement
- Configure both targets in Xcode project to use their respective entitlements

**Step 3.4** — Configure code signing
- Both main app and widget extension must be signed with the same Team ID
- For local development: self-signed certificate or Apple Development certificate
- For distribution: Developer ID certificate (required for App Group access)
- Update build scripts to pass signing identity and entitlements

**Step 3.5** — Update build scripts
- `scripts/build_app.sh` — include widget extension in app bundle
- Widget goes to `ClearDisk.app/Contents/Extensions/ClearDiskWidget.appex`
- Add `codesign` steps for both the extension and the main app with entitlements

**Step 3.6** — Update `Info.plist`
- Add `NSExtension` dictionary for widget
- Configure `NSExtensionPointIdentifier: com.apple.widgetkit-extension`

### Phase 4: Deep Links & Interactivity

**Step 4.1** — Register URL scheme `cleardisk://`
- `cleardisk://open` — open main popover
- `cleardisk://scan` — trigger fresh scan
- `cleardisk://clean` — open clean screen

**Step 4.2** — Add widget tap actions
- Small widget: tap opens app
- Medium widget: "Open App" button
- Large widget: "Open ClearDisk" button, tap on cache category opens relevant tab

**Step 4.3** — Handle URL scheme in `ClearDiskApp.swift`
- Parse incoming URL and route to appropriate action

### Phase 5: Polish & Edge Cases

**Step 5.1** — Widget previews and placeholder data
- Create realistic mock data for widget gallery
- Ensure placeholder looks good before first scan

**Step 5.2** — Stale data handling
- If `widget-data.json` is older than 30 minutes, show "Scanning..." state
- If file doesn't exist (first launch), show onboarding hint

**Step 5.3** — Accessibility
- VoiceOver labels for progress ring
- Dynamic Type support
- High contrast mode support

**Step 5.4** — Dark mode / light mode
- Widget automatically adapts via SwiftUI environment
- Ensure all custom colors have both variants

---

## 8. Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Data sharing mechanism | App Group container + shared JSON file | Widget Extensions are always sandboxed; App Groups is the only reliable IPC mechanism |
| Widget refresh strategy | App-triggered + 15min fallback | Fresh data after each scan, fallback if app not running |
| Build system | Xcode project wrapping SPM | Only viable way to embed Widget Extension |
| Widget families | Small + Medium + Large | Each serves different dashboard density needs |
| Interactivity | URL scheme deep links | WidgetKit supports `Link` and `widgetURL` for navigation |
| Shared code | Local SPM package | Clean separation, compiled into both targets |

---

## 9. Dependencies

**No new external dependencies required.** Everything uses Apple frameworks:
- `WidgetKit` — widget infrastructure
- `SwiftUI` — widget UI (already used)
- `Foundation` — JSON encoding (already used)

---

## 10. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| SPM doesn't support Widget Extensions | Build system complexity | Minimal Xcode project wrapper; keep SPM for shared code |
| Widget extension is always sandboxed | Cannot read arbitrary paths | App Group container is the sole data exchange point; main app writes pre-computed data there |
| WidgetKit has 15-min minimum refresh | Stale data possible | App-triggered reload after each scan; "Last updated" timestamp |
| Code signing required for App Groups | Both app and extension must be signed | Provide Developer ID signing guide; local dev uses self-signed certificate; CI signs with team cert |
| Widget extension code signing | Distribution complexity | Document signing steps; entitlements template included in repo |

---

## 11. Testing Strategy

1. **Unit tests:** `WidgetData` encoding/decoding round-trip
2. **Unit tests:** `WidgetDataWriter` produces valid JSON from mock `DiskMonitor` state
3. **Unit tests:** `WidgetDataReader` handles missing file, corrupt file, stale file
4. **SwiftUI Previews:** All three widget sizes with mock data
5. **Integration:** Main app scan → widget data file → widget displays correct values
6. **Manual:** Add widget to desktop, verify updates after app scan

---

## 12. Implementation Priority

```
Priority 1 (MVP):  Shared data layer + Small widget
Priority 2:        Medium widget + timeline refresh
Priority 3:        Large widget + deep links
Priority 4:        Polish, accessibility, edge cases
```

Estimated file count: **~10 new files**, **~2 modified files**
