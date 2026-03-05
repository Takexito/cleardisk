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

**Solution:** Migrate to a hybrid build:
- Create an `.xcodeproj` via `xcodebuild` or manually
- The main app becomes an App target (not executable)
- The widget becomes a Widget Extension target embedded in the app
- Shared code lives in a local Swift Package or shared framework

**Alternative (Recommended for this project):** Keep SPM for the main app, add a standalone **companion Xcode project** specifically for the widget that reads shared data. This avoids disrupting the existing build pipeline.

### 2.2 Data Sharing Between App & Widget

**Problem:** The widget runs in a separate process (extension sandbox). It cannot directly access `DiskMonitor`'s in-memory state.

**Solution:** Use **App Groups** + shared `UserDefaults` / JSON file:

```
App Group: group.com.cleardisk.shared
├── shared UserDefaults (lightweight metrics)
└── shared container file: widget-data.json (full cache breakdown)
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

```
~/Library/Group Containers/group.com.cleardisk.shared/widget-data.json
```

Fallback (if App Groups unavailable without signing):
```
~/Library/Application Support/ClearDisk/widget-data.json
```

Since ClearDisk is distributed outside the App Store and is not sandboxed, both app and widget extension can read/write to a known shared path without App Groups. This simplifies the implementation significantly.

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
│   └── SharedPaths.swift           # Shared file paths constants
│
└── ClearDiskWidget/                # NEW — Widget Extension
    ├── ClearDiskWidget.swift       # Widget entry point + configuration
    ├── WidgetTimelineProvider.swift # TimelineProvider implementation
    ├── WidgetDataReader.swift      # Reads shared JSON
    └── Views/
        ├── SmallWidgetView.swift   # .systemSmall layout
        ├── MediumWidgetView.swift  # .systemMedium layout
        └── LargeWidgetView.swift   # .systemLarge layout
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
- Define shared file path: `~/Library/Application Support/ClearDisk/widget-data.json`
- Helper to ensure directory exists

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

### Phase 3: Build System Integration

**Step 3.1** — Create Xcode project for widget extension
- Since SPM doesn't support app extensions, create a minimal `.xcodeproj`
- Main app target embeds the widget extension
- Shared code compiled into both targets

**Step 3.2** — Update `Package.swift`
- Add a library target for shared code
- Keep executable target for main app

**Step 3.3** — Update build scripts
- `scripts/build_app.sh` — include widget extension in app bundle
- Widget goes to `ClearDisk.app/Contents/Extensions/ClearDiskWidget.appex`

**Step 3.4** — Update `Info.plist`
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
| Data sharing mechanism | Shared JSON file | No App Groups needed (non-sandboxed app), simple, debuggable |
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
| Widget extension is sandboxed | Cannot read arbitrary paths | Main app writes pre-computed data to known shared location |
| WidgetKit has 15-min minimum refresh | Stale data possible | App-triggered reload after each scan; "Last updated" timestamp |
| Non-signed app can't use App Groups | Data sharing limitation | Use shared filesystem path instead (app is not sandboxed) |
| Widget extension code signing | Distribution complexity | Document signing steps; provide unsigned dev workflow |

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
