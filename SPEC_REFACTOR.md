# SPEC_REFACTOR.md — Phased Refactor Spec for the `Training` App

> Audience: a coding agent that will execute this spec **mechanically**. Do not improvise.
> This document was written after reading every source and test file in the repo.
> Where the spec is uncertain, it says so and gives a **safe default** so you are never blocked.

---

## 0. HOW TO USE THIS SPEC (read this first)

1. **Work phases strictly in order**: Phase 0 → Phase 1 → Phase 2 → Phase 3 → Phase 4.
2. **Within a phase, do tasks in listed order.** Each task has a stable ID (e.g. `P0-T1`).
3. **After EVERY task**: run the build and the test suite (commands in §3). Fix anything you broke before moving on.
4. **Do not start a later phase until every acceptance criterion of the current phase passes.**
5. **Never edit two copies of a file.** After `P0-T1` there is exactly ONE copy of each `.swift` logic file. If you ever see two, stop and re-check `P0-T1`.
6. **Anchor edits by symbol name, not just line number.** Line numbers in this spec are correct as of writing, but they shift as you edit. Every task also names the function/type to edit.
7. If a task says a pre-existing test encodes a wrong expectation, **update the test as instructed** — the spec's acceptance criteria are the source of truth, not the old test.
8. Only touch files this spec names. Do not do "drive-by" cleanups.

---

## 1. CANONICAL SOURCE TREE — THE SINGLE MOST IMPORTANT DECISION

**There are currently TWO byte-identical copies of every logic file:**

- `Sources/TrainingApp/**` — a Swift Package Manager (SPM) *library* target named `TrainingApp`. Compiled by `swift build` / `swift test`. Has NO app entry point.
- `Training/Training/**` — the source folder of an Xcode iOS app target (`Training/Training.xcodeproj`). Has the real app: `TrainingApp.swift` (`@main`), `Training.entitlements` (HealthKit), `Assets.xcassets`. Compiled by Xcode via a `PBXFileSystemSynchronizedRootGroup` (Xcode auto-compiles every file under `Training/Training/`).

I verified: the 16 shared `.swift` files are **identical** between the two trees. The Xcode project does **not** reference the SPM package; it compiles its own copy. This duplication exists because the app needs HealthKit entitlements + an `Info.plist` (auto-generated) + an iOS `@main` App, which is why the author kept an Xcode app target, while also keeping an SPM library so the logic is unit-testable headlessly (`swift test`).

### DECISION (locked): The canonical tree is **`Training/Training/`**.

After `P0-T1`, `Sources/TrainingApp/` is **deleted**, and `Package.swift` is repointed so `swift build` / `swift test` compile the files in `Training/Training/`. Result: **exactly one physical copy** of every logic file, compiled by BOTH build systems.

**Why this arrangement (and not the reverse):**
- It requires **zero edits to the Xcode project file** (`project.pbxproj`). Hand-editing an `.xcodeproj` is error-prone, and this environment cannot fully verify an Xcode/iOS build. By leaving the Xcode project untouched, the app's buildability is preserved *by construction*.
- Your verifiable feedback loop (`swift test`) then exercises the exact same files the app ships.
- One copy ⇒ you are never confused about which file to edit.

**Every file path in this spec points at `Training/Training/…`.** (Before `P0-T1` runs, the same line numbers are also valid in `Sources/TrainingApp/…`, since the copies are identical.)

> Git note (informational, low priority): `Training/` currently contains its **own nested `.git`** (it is a separate git repo), which is why the outer repo shows `Training/` as one untracked entry. `P0-T1` includes an OPTIONAL, safe step to remove that nested `.git` so the outer repo tracks the canonical files normally. If you are unsure, **skip the git step** — it does not affect building, testing, or which file to edit.

---

## 2. DEPENDENCY GRAPH / ORDERING SUMMARY

```
Phase 0 (Foundation & crash safety) — blocks everything
  P0-T1  Source-tree convergence .......... (no deps)
  P0-T2  Unblock test compilation ......... needs P0-T1
  P0-T3  Model name + reasoner params ..... needs P0-T1
  P0-T4  VM ownership (@State) ............ needs P0-T1 (coordinate w/ P0-T2)
  P0-T5  Remove DB force-unwraps .......... needs P0-T1
  P0-T6  DB thread-safety + pragmas ....... needs P0-T1
  P0-T7  Instance-owned ToolRegistry ...... needs P0-T1
  P0-T8  Cheap init + async bootstrap ..... needs P0-T5, P0-T6, P0-T7

Phase 1 (Data correctness)
  P1-T1  Unify activity source = activity_log ... needs P0-T8
  P1-T2  Transaction for paired writes ........... needs P0-T6
  P1-T3  Schema version + migrations ............. needs P0-T6
  P1-T4  Dedup call_id in ToolRegistry ........... needs P0-T7
  P1-T5  Fix AnyCodable decimal truncation ....... needs P0-T1

Phase 2 (LLM / networking robustness)
  P2-T1  Selective retries + cancellation ........ needs P0-T3
  P2-T2  Harden extractJSON ...................... needs P0-T1
  P2-T3  Fix malformed planner example JSON ...... needs P0-T1
  P2-T4  Injection-safe deterministic render ..... needs P0-T1
  P2-T5  Preserve decode error + optional usage .. needs P0-T3 (same file as P2-T1)

Phase 3 (Performance / correctness / UX)
  P3-T1  HKStatisticsCollectionQuery ............. needs P0-T1  (RISKIEST — see safe default)
  P3-T2  isHealthDataAvailable + auth result ..... needs P0-T4
  P3-T3  Cost: reconcile semantics + CostBarView . needs P0-T4, P0-T8
  P3-T4  Dead/duplicated code cleanup ............ needs P0-T1 (recovery fn shared w/ P3-T2 area)

Phase 4 (Hygiene & tests)
  P4-T1  os.Logger + remove print noise .......... do after code is stable
  P4-T2  Remove hardcoded message filter ......... needs P0-T8
  P4-T3  Rename StreamingTests ................... (no deps)
  P4-T4  Add/adjust tests ........................ needs the features it tests
```

---

## 3. BUILD & TEST COMMANDS

Run from the repo root `<repo-root>`.

**Primary loop (use this after every task):**
```bash
swift build
swift test
```

- `swift test` is the authoritative feedback loop. All tests use in-memory SQLite, mocked networking (`URLProtocol`), or pure functions — **no real network or HealthKit is exercised**, so tests are deterministic.
- Environment caveat observed while writing this spec: `swift` invokes `sandbox-exec` internally to compile the package manifest. If you run inside a nested sandbox you may see `sandbox-exec: sandbox_apply: Operation not permitted`. Run in a normal shell (no extra sandbox) and it works. If blocked, that is an environment issue, not a code issue.

**Optional app build (author-only, not part of your per-task loop):**
```bash
xcodebuild -project Training/Training.xcodeproj -scheme Training \
  -destination 'generic/platform=iOS' build
```
- This needs Xcode + iOS SDK/simulator and may print CoreSimulator warnings. You (the agent) are **not** required to run this. The Xcode project is untouched by this spec, so if `swift build` compiles the shared files, the app target compiles the same files.

**Baseline reality (verified):** as of now `swift build` succeeds, but `swift test` **fails to compile** because `RecordModeTests.swift` references API that does not exist yet (`vm.isRecordMode`) and mutates a `let` (`ActivityLog.intensity`). `P0-T2` fixes this so you have a green baseline before doing correctness work.

---

## 4. PHASE 0 — FOUNDATION & CRASH SAFETY

### P0-T1 — Converge to a single source tree
**Depends on:** none.
**Files:** `Package.swift`; delete `Sources/TrainingApp/**`; (optional) `Training/.git`.

**Change:**

1. Edit `Package.swift` so the `TrainingApp` target compiles `Training/Training/`, excluding app-only files. Replace the whole file with:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Training",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "TrainingApp", targets: ["TrainingApp"]),
    ],
    targets: [
        .target(
            name: "TrainingApp",
            path: "Training/Training",
            exclude: [
                "TrainingApp.swift",     // @main App entry point — app target only
                "Training.entitlements", // HealthKit entitlement — app target only
                "Assets.xcassets",       // app assets — app target only
            ]
        ),
        .testTarget(
            name: "TrainingAppTests",
            dependencies: ["TrainingApp"]
            // tests stay at Tests/TrainingAppTests (SPM default)
        ),
    ]
)
```

2. **Delete the entire `Sources/` directory** (`Sources/TrainingApp/**`). It is now redundant. Use your file-delete tool for each file, or `rm -rf Sources`.

3. **(OPTIONAL, safe) Remove the nested git repo** so the outer repo tracks the canonical files:
   ```bash
   rm -rf Training/.git
   ```
   Only files' *history* inside the nested repo is discarded; all working files remain. If you are unsure, **skip this** — it changes nothing about building/testing.

**Rationale:** eliminates the duplicate second copy so there is one unambiguous edit target, while keeping both build systems working.

**Acceptance criteria:**
- `Sources/` no longer exists.
- `ls Training/Training/*.swift` still shows all logic files (`ChatViewModel.swift`, `DatabaseService.swift`, `ContentView.swift`, …) and `Training/Training/Tools/*.swift`.
- `swift build` succeeds (it now compiles files under `Training/Training/`).
- `swift test` still *compiles the test target* against module `TrainingApp` (it will still fail at `RecordModeTests` until `P0-T2`; that is expected here).
- `grep -R "deepseek" Sources 2>/dev/null` returns nothing (folder gone).

---

### P0-T2 — Unblock test compilation
**Depends on:** P0-T1.
**Files:** `Training/Training/Models.swift`, `Training/Training/ChatViewModel.swift`, `Training/Training/ContentView.swift`.
**Problem:** `Tests/TrainingAppTests/RecordModeTests.swift` (lines 26, 35–37) does `updated.intensity = "medium"` (needs a mutable property) and `vm.isRecordMode` (needs a property on the view model). Neither exists, so the whole suite fails to compile.

**Change:**

1. In `Models.swift`, make `ActivityLog`'s stored properties mutable. Change the `struct ActivityLog` (currently lines 24–33) so every `let` becomes `var`:
```swift
struct ActivityLog: Codable, Identifiable {
    var id: UUID
    var date: Date
    var type: String
    var durationMin: Double?
    var distanceKm: Double?
    var intensity: String?
    var notes: String?
    var createdAt: Date
}
```
   (Codable/Identifiable behavior is unchanged; `var` is a superset of `let`.)

2. In `ChatViewModel.swift`, add observable record-mode state to the `@Observable final class ChatViewModel`. Add this stored property next to `messages`/`errorMessage`/`isLoading` (near line 37):
```swift
    var isRecordMode: Bool = false
```

3. In `ContentView.swift`, move record-mode state from a local `@State` to the view model so it is a single source of truth. Currently line 6 is `@State private var isRecordMode = false`.
   - **Delete** line 6 (`@State private var isRecordMode = false`).
   - The view already owns the VM; make a binding available in `body`. At the very top of `var body: some View` (before the `VStack`), add:
```swift
        @Bindable var viewModel = viewModel
```
   - Replace the three `isRecordMode` usages so they go through the VM:
     - line 29 `Picker("Mode", selection: $isRecordMode)` → `Picker("Mode", selection: $viewModel.isRecordMode)`
     - line 35 `if isRecordMode {` → `if viewModel.isRecordMode {`
     - line 66 `.onChange(of: isRecordMode) { _, new in` → `.onChange(of: viewModel.isRecordMode) { _, new in`

**Rationale:** makes the test target compile and centralizes UI mode state in the observable VM (matches what `RecordModeTests.testModeToggle` expects).

**Acceptance criteria:**
- `swift build` and `swift test` both **compile**.
- `swift test` now **runs**. Record-mode + model/CRUD tests in `RecordModeTests` pass:
  - `RecordModeTests.testCRUD`, `testUpdate`, `testModeToggle` pass.
- Note: a few other pre-existing tests may still fail here (they assert unimplemented behavior — `Batch2Tests.testManualRecordingWritesActivity`, and possibly `Batch1Tests.testDBFailureDoesntCrash` if a real `training.db` exists). These are addressed in `P1-T1` and `P0-T8` respectively. Record which tests pass now so you can tell what later tasks fix.

---

### P0-T3 — Fix model name (`deepseek-v4-pro` → `deepseek-reasoner`) and adjust request params
**Depends on:** P0-T1.
**Files:** `Training/Training/Models.swift`, `Training/Training/ChatViewModel.swift`, `Training/Training/DeepSeekClient.swift`.

**Change:**

1. Add a single configurable model constant in `Models.swift`, inside `enum AppConfig` (currently lines 52–54):
```swift
enum AppConfig {
    static let deepSeekAPIKey = "YOUR_DEEPSEEK_API_KEY"
    static let deepSeekModel = "deepseek-reasoner"
}
```
   > NOTE / author-confirm: this app targets `deepseek-reasoner`. Because everything flows through this one constant, switching models later (e.g. to another DeepSeek chat model) is a one-line change. Safe default = `"deepseek-reasoner"`.

2. In `ChatViewModel.swift`, replace both hardcoded `model: "deepseek-v4-pro"` occurrences:
   - line 213 (executor call inside `sendMessage`) `model: "deepseek-v4-pro",` → `model: AppConfig.deepSeekModel,`
   - line 286 (planner call inside `callPlanner`) `model: "deepseek-v4-pro",` → `model: AppConfig.deepSeekModel,`

3. In `DeepSeekClient.swift`, adjust request-body construction for reasoning models. `deepseek-reasoner` **ignores** `temperature` (and `top_p`, `presence_penalty`, `frequency_penalty`) — the API silently accepts but ignores them; it also does not support function-calling / JSON-output modes and returns an extra `reasoning_content` field which this app does not need (each call is a stateless 2-message request, so there is no multi-turn `reasoning_content` pass-back requirement).
   Replace the body-building block in `performRequest` (currently lines 65–71):
```swift
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
        ]
        // deepseek-reasoner ignores temperature (and top_p/penalties). Only send
        // temperature for non-reasoning models so the request is honest.
        if !model.contains("reasoner") {
            body["temperature"] = temperature
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
```
   > NOTE / author-confirm: whether `deepseek-reasoner` needs a larger `max_tokens` (reasoning tokens count against the budget) is for the author to confirm. **Safe default: leave the existing `maxTokens` values (planner 1000, executor 2000).** They are harmless; if the planner JSON ever gets truncated, the author can raise the planner `maxTokens`.

**Rationale:** `deepseek-v4-pro` is not the intended model; route all model selection through one constant and stop sending a parameter the reasoning model ignores.

**Acceptance criteria:**
- `grep -R "deepseek-v4-pro" Training` returns nothing.
- `DeepSeekClientTests` still passes. In particular `testRequestBody` calls `chat(model: "deepseek-chat", …)` and asserts `temperature == 0.7` is present — because `"deepseek-chat"` does not contain `"reasoner"`, temperature is still sent. ✅
- `swift test` passes at least as many tests as after `P0-T2`.

---

### P0-T4 — View-model ownership: store `ChatViewModel` as `@State`
**Depends on:** P0-T1. Coordinate with P0-T2 (same file).
**File:** `Training/Training/ContentView.swift` (line 5).

**Problem & rationale (explain to yourself so you get this right):** `ChatViewModel` is `@Observable`. With the Observation framework, a SwiftUI `View` that **creates and owns** an observable object must store it in `@State`, otherwise SwiftUI reconstructs the object on every view re-render (losing all its state, re-opening the DB, etc.) and does not correctly establish observation of it. Child views that merely *receive* an already-owned `@Observable` object should take it as a **plain `let`/`var` property** (they observe through it automatically) — those do NOT need `@State`. So: the *owner* (`ContentView`) uses `@State`; the receivers (`InputBarView`, `RecordModeView`, `CostBarView`) keep plain properties.

**Change:** In `ContentView`, line 5:
```swift
    private var viewModel = ChatViewModel()
```
→
```swift
    @State private var viewModel = ChatViewModel()
```
Leave `InputBarView.viewModel`, `RecordModeView.viewModel` as plain `var` (unchanged).

**Acceptance criteria:**
- `ContentView` declares `@State private var viewModel = ChatViewModel()`.
- `swift build` succeeds. (Runtime state-persistence is validated by the author in the app; there is no headless test for SwiftUI ownership.)

---

### P0-T5 — Remove force-unwraps in DB row mapping
**Depends on:** P0-T1.
**File:** `Training/Training/DatabaseService.swift`.
**Problem:** `mapChatMessage` (lines 195–215) force-unwraps `UUID(uuidString: id)!` (line 206) and `parseDate(createdAtString)!` (line 213). `mapActivityLog` (lines 277–298) force-unwraps `UUID(uuidString: id)!` (line 289), `parseDate(dateString)!` (line 290), `parseDate(createdAtString)!` (line 296). A malformed/corrupt row crashes the whole app. Note: `queryAllActivities` (lines 143–160) already uses the safe `?? UUID()` / `?? Date()` pattern.

**Change:** Make both mappers return optionals and **skip** bad rows.

1. Change `mapChatMessage` to `-> ChatMessage?` and replace the force-unwraps:
```swift
    private func mapChatMessage(_ stmt: OpaquePointer) -> ChatMessage? {
        let idString = String(cString: sqlite3_column_text(stmt, 0))
        let role = String(cString: sqlite3_column_text(stmt, 1))
        let content = String(cString: sqlite3_column_text(stmt, 2))
        let fullRequest = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let tokenIn = Int(sqlite3_column_int64(stmt, 4))
        let tokenOut = Int(sqlite3_column_int64(stmt, 5))
        let cost = sqlite3_column_double(stmt, 6)
        let createdAtString = String(cString: sqlite3_column_text(stmt, 7))

        guard let id = UUID(uuidString: idString),
              let createdAt = parseDate(createdAtString) else {
            return nil   // skip corrupt row instead of crashing
        }
        return ChatMessage(
            id: id, role: role, content: content, fullRequest: fullRequest,
            tokenIn: tokenIn, tokenOut: tokenOut, cost: cost, createdAt: createdAt
        )
    }
```

2. Update its callers:
   - `queryChatMessage(id:)` (line 126): `return mapChatMessage(stmt)` — type now `ChatMessage?`, still fine (already returns optional).
   - `queryRecentMessages` loop (lines 137–139): change to skip nils:
```swift
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let m = mapChatMessage(stmt) { messages.append(m) }
        }
```

3. Change `mapActivityLog` to `-> ActivityLog?` similarly:
```swift
    private func mapActivityLog(_ stmt: OpaquePointer) -> ActivityLog? {
        let idString = String(cString: sqlite3_column_text(stmt, 0))
        let dateString = String(cString: sqlite3_column_text(stmt, 1))
        let type = String(cString: sqlite3_column_text(stmt, 2))
        let durationMin: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
        let distanceKm: Double? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4)
        let intensity: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5))
        let notes: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 6))
        let createdAtString = String(cString: sqlite3_column_text(stmt, 7))

        guard let id = UUID(uuidString: idString),
              let date = parseDate(dateString),
              let createdAt = parseDate(createdAtString) else {
            return nil
        }
        return ActivityLog(
            id: id, date: date, type: type, durationMin: durationMin,
            distanceKm: distanceKm, intensity: intensity, notes: notes, createdAt: createdAt
        )
    }
```
   - `queryActivityLog(id:)` (line 274): `return mapActivityLog(stmt)` — still fine (returns optional).

**Rationale:** a single corrupt row must not crash a personal daily-use app; skip-on-error matches the existing `queryAllActivities` philosophy.

**Acceptance criteria:**
- No `!` force-unwrap remains in `mapChatMessage` / `mapActivityLog` (`grep -n "uuidString: .*)!" Training/Training/DatabaseService.swift` and `grep -n "parseDate(.*)!" …` return nothing).
- Existing DB tests still pass (`DatabaseServiceTests.*`).
- New test added in `P4-T4` (`testMalformedRowIsSkippedNotCrash`) passes.

---

### P0-T6 — DB thread-safety: one connection behind a serial queue + pragmas
**Depends on:** P0-T1.
**File:** `Training/Training/DatabaseService.swift`.
**Problem:** `DatabaseService` wraps one `sqlite3*` but has no serialization; concurrent access (VM on `@MainActor` + tools on background continuations) can corrupt state. No `busy_timeout`, no WAL.

**Change:**

1. Add a serial queue and a helper. Near the top of `final class DatabaseService` (after `private var db: OpaquePointer?`, line 7):
```swift
    private let queue = DispatchQueue(label: "training.db.serial")

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }
```

2. Set pragmas in `init(databasePath:)` right after `createTables()` (line 20). Keep them tolerant of `:memory:`:
```swift
        try createTables()
        // Reduce "database is locked" errors and enable concurrent readers.
        sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) // no-op/harmless for :memory:
```

3. **Route every public method's body through `sync { … }`.** These public methods must be wrapped: `insertChatMessage`, `queryChatMessage`, `queryRecentMessages`, `queryAllActivities`, `deleteActivity`, `updateActivity`, `sumCost`, `insertActivityLog`, `queryActivityLog`, `setUserProfile`, `getUserProfile`, `deleteUserProfile`. Pattern (example for `sumCost`):
```swift
    func sumCost() throws -> Double {
        try sync {
            let sql = "SELECT COALESCE(SUM(cost), 0.0) FROM chat_message"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0.0 }
            return sqlite3_column_double(stmt, 0)
        }
    }
```
   Do the same mechanical wrap for each listed method: put the entire existing body inside `try sync { … }` (use `sync { … }` without `try` for non-throwing bodies — but all listed ones throw, so use `try sync`).
   **Important — do NOT wrap the private helpers** (`exec`, `prepare`, `formatDate`, `parseDate`, `mapChatMessage`, `mapActivityLog`, `createTables`). They are called from *inside* already-locked public methods; wrapping them would deadlock (`DispatchQueue.sync` is non-reentrant).
   **Do NOT** wrap `deinit`'s `sqlite3_close`.

**Rationale:** a single serialized connection with `busy_timeout` + WAL is the minimal, low-ripple way to make SQLite access safe here. (An `actor` would force `await` at dozens of synchronous call sites and tests — too invasive.)

**Acceptance criteria:**
- Every listed public method's body is inside `try sync { … }`.
- No private helper is wrapped (no nested `sync`).
- `swift test` passes all DB tests (`DatabaseServiceTests`, `LogActivityToolTests`, `RecordModeTests` CRUD/update) — this proves no deadlock and no reentrancy bug.

---

### P0-T7 — Instance-owned `ToolRegistry` (stop global re-registration)
**Depends on:** P0-T1.
**Files:** `Training/Training/Tools/ToolProtocol.swift`, `Training/Training/ChatViewModel.swift`.
**Problem:** `ToolRegistry.shared` (ToolProtocol.swift line 93) is a process-global singleton. `ChatViewModel.convenience init()` (ChatViewModel.swift lines 90–96) registers 6 tools into it every time a VM is created (every test, every `ContentView` init). Global mutable shared state = test cross-talk and hidden coupling.

**Change:**

1. In `ToolProtocol.swift`, remove the singleton. Delete line 93 (`static let shared = ToolRegistry()`). Keep the rest of `final class ToolRegistry`.

2. In `ChatViewModel.swift`:
   - Add a stored registry to the class. Next to `private let deepSeekService` / `messageStore` / `costTracker` (lines 74–76), add:
```swift
    private let toolRegistry: ToolRegistry
```
   - Add it to the **designated** `init` (lines 78–86) as a parameter with a default so existing tests that call the designated init keep working:
```swift
    init(
        deepSeekService: DeepSeekService,
        messageStore: MessageStore,
        costTracker: CostTracker,
        toolRegistry: ToolRegistry = ToolRegistry()
    ) {
        self.deepSeekService = deepSeekService
        self.messageStore = messageStore
        self.costTracker = costTracker
        self.toolRegistry = toolRegistry
    }
```
   - In `convenience init()` (lines 88–109), build a local registry and pass it in (final wiring is finished in `P0-T8`; for now just replace `ToolRegistry.shared` with a local `registry` you create and pass through `self.init(... toolRegistry: registry)`).
   - Replace the two `ToolRegistry.shared.execute(...)` call sites:
     - line 67 (in `logActivityViaPlanner`): `await ToolRegistry.shared.execute([logTool])` → `await toolRegistry.execute([logTool])`
     - line 186 (in `sendMessage`): `await ToolRegistry.shared.execute(plannerResponse.response.tools)` → `await toolRegistry.execute(plannerResponse.response.tools)`

**Rationale:** each VM owns its tools; no global state; tests are isolated.

**Acceptance criteria:**
- `grep -R "ToolRegistry.shared" Training` returns nothing.
- `swift test` passes (designated-init tests use the defaulted empty registry, same behavior as before).

---

### P0-T8 — Cheap init + async bootstrap; share the DB connection into tools
**Depends on:** P0-T5, P0-T6, P0-T7.
**Files:** `Training/Training/ChatViewModel.swift`, `Training/Training/ContentView.swift`, `Training/Training/Tools/ProfileTools.swift`.
**Problem:** `convenience init()` (lines 88–109) synchronously opens the DB, registers tools, runs `sumCost()` and `queryRecentMessages(100)` on the main thread during *view construction*. Also `ManualActivitiesTool` opens a **second** `DatabaseService` connection to the same file (ProfileTools.swift line 9).

**Change:**

1. **Inject the shared DB connection into `ManualActivitiesTool`.** In `ProfileTools.swift`, give it a stored `DatabaseService` (same style as `LogActivityTool`). Replace the top of `ManualActivitiesTool` (lines 3–9) so it holds `private let store: DatabaseService` set via `init(store:)`, and its `execute` uses `store` instead of `try DatabaseService(databasePath: dbPath())`. (The full query rewrite to read `activity_log` happens in `P1-T1`; for this task just make it use the injected `store` with the current logic so it compiles.)
   Also remove the now-unused `dbPath()` helper from `ManualActivitiesTool` (lines 22–24).

2. **Rewrite `convenience init()` to be cheap** and register tools once, sharing the one DB:
```swift
    convenience init() {
        let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first! + "/training.db"
        let db = (try? DatabaseService(databasePath: dbPath)) ?? (try! DatabaseService(databasePath: ":memory:"))

        let registry = ToolRegistry()
        registry.register(MetricTool())
        registry.register(SleepTableTool())
        registry.register(WorkoutTableTool())
        registry.register(DailySummaryTool())
        registry.register(ManualActivitiesTool(store: db))   // shares the one connection
        registry.register(UserProfileTool())
        registry.register(LogActivityTool(store: db))

        self.init(
            deepSeekService: DeepSeekClient(apiKey: AppConfig.deepSeekAPIKey),
            messageStore: db,
            costTracker: CostTracker(),          // history total loaded later in bootstrap()
            toolRegistry: registry
        )
        // NOTE: no history query and no sumCost() here — moved to bootstrap().
    }
```

3. **Add an async `bootstrap()`** to `ChatViewModel` that does the heavy DB reads off view-construction. Add this method (near `sendMessage`):
```swift
    func bootstrap() async {
        guard let db = messageStore as? DatabaseService else { return }
        if let historyTotal = try? db.sumCost() {
            costTracker.setHistoryTotal(historyTotal)
        }
        if let recent = try? db.queryRecentMessages(limit: 100), !recent.isEmpty {
            // queryRecentMessages returns newest-first; UI wants oldest-first.
            messages = recent.reversed()
        }
    }
```
   (The old hardcoded content filter is intentionally gone — see `P4-T2`, which this task already satisfies.)

4. **Make `CostTracker.allTimeTotal` updatable.** In `CostTracker.swift`, change `private let allTimeTotal: Double` (line 65) to `private var allTimeTotal: Double` and add:
```swift
    func setHistoryTotal(_ total: Double) {
        allTimeTotal = total
    }
```

5. **Call `bootstrap()` from `ContentView`.** In `ContentView.body`'s `.task` (line 62), add the bootstrap call first:
```swift
        .task { await viewModel.bootstrap(); await requestHealthAuth(); await refreshStatusBar() }
```

**Rationale:** view construction becomes cheap and side-effect-light; the DB is opened once and shared; history/cost load asynchronously; no second SQLite connection.

**Acceptance criteria:**
- `ManualActivitiesTool` has `init(store: DatabaseService)` and no longer constructs a `DatabaseService`. `grep -n "DatabaseService(" Training/Training/Tools/ProfileTools.swift` returns nothing.
- `convenience init()` contains no `sumCost()` and no `queryRecentMessages`.
- `ChatViewModel` has `func bootstrap() async`; `CostTracker` has `setHistoryTotal(_:)`.
- `swift test` passes; specifically `Batch1Tests.testDBFailureDoesntCrash` now reliably passes because `convenience init()` no longer loads messages (so `vm.messages.isEmpty` is true right after construction).

---

## 5. PHASE 1 — DATA CORRECTNESS

### P1-T1 — Unify the activity data source to `activity_log`
**Depends on:** P0-T8.
**File:** `Training/Training/Tools/ProfileTools.swift`.
**Problem:** `ManualActivitiesTool.execute` (lines 6–20) reads `chat_message` and **re-parses user chat text** with `ActivityParser`. But real activities are written to the `activity_log` table by `LogActivityTool`. So the tool reports a different, lossy source than the truth. `RecordModeView` already reads `activity_log` (via `viewModel.loadActivities()` → `queryAllActivities`), so only this tool is wrong.

**Change:** Rewrite `ManualActivitiesTool.execute` to read `activity_log` through the injected `store`, honoring an optional `range` (in days):
```swift
    func execute(params: [String: String]) async -> String {
        let range = Int(params["range"] ?? "") // nil => no limit
        var rows = ["| 日期 | 类型 | 时长 | 距离 | 强度 | 备注 |"]
        let logs = (try? store.queryAllActivities()) ?? []
        let cutoff: Date? = range.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        for log in logs {
            if let cutoff, log.date < cutoff { continue }
            let dur = log.durationMin.map { "\(Int($0))m" } ?? "—"
            let dist = log.distanceKm.map { "\(String(format: "%.1f", $0))km" } ?? "—"
            rows.append("| \(ds(log.date)) | \(log.type) | \(dur) | \(dist) | \(log.intensity ?? "—") | \(log.notes ?? "") |")
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : "无手动记录"
    }
```
Keep the `ds(_:)` helper. `ActivityParser` is no longer used by this tool. (Do **not** delete `ActivityParser` — it is still covered by `ActivityParserTests` and may be reused; leave it as-is.)

**Rationale:** single source of truth for activities = the `activity_log` table that `log_activity` writes to.

**Acceptance criteria:**
- `ManualActivitiesTool.execute` references `store.queryAllActivities()` and does not mention `ActivityParser` or `queryRecentMessages`.
- New test (`P4-T4`, `testManualActivitiesReadsActivityLog`): insert an `ActivityLog` into an in-memory DB, build `ManualActivitiesTool(store: db)`, call `execute(params: [:])`, expect the output to contain that activity's `type`.
- Fix `Batch2Tests.testManualRecordingWritesActivity` (see `P4-T4`) — it currently asserts an unimplemented behavior.

---

### P1-T2 — Wrap paired chat-message writes in a transaction
**Depends on:** P0-T6.
**Files:** `Training/Training/DatabaseService.swift`, `Training/Training/ChatViewModel.swift`.
**Problem:** `sendMessage` inserts the user message and the assistant message as two separate writes (lines 246–252, and the fallback path lines 167–168). A crash/failure between them leaves the DB half-written.

**Change:**

1. Add a private non-locking insert and a transactional pair method to `DatabaseService`.
   - Rename the *body* of the existing `insertChatMessage` into a private helper `_insertChatMessage` that assumes it is already on the queue (i.e. NOT wrapped in `sync`), and make the public `insertChatMessage` just `try sync { try _insertChatMessage(message) }`.
   - Add:
```swift
    func insertChatMessagePair(_ first: ChatMessage, _ second: ChatMessage) throws {
        try sync {
            try exec("BEGIN")
            do {
                try _insertChatMessage(first)
                try _insertChatMessage(second)
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }
```

2. Add the method to the `MessageStore` protocol with a default so mocks keep working. In `ChatViewModel.swift`, extend the `protocol MessageStore` (lines 26–30) with `func insertChatMessagePair(_ first: ChatMessage, _ second: ChatMessage) throws` and add a default:
```swift
extension MessageStore {
    func insertChatMessagePair(_ first: ChatMessage, _ second: ChatMessage) throws {
        try insertChatMessage(first)
        try insertChatMessage(second)
    }
}
```
   (`DatabaseService`'s real implementation overrides the default with the transactional one.)

3. In `sendMessage`, replace the two-call save block (lines 246–252):
```swift
            do {
                try messageStore.insertChatMessagePair(userMessage, assistantMessage)
            } catch {
                // logged via os.Logger in P4-T1
            }
```
   And the fallback save (lines 167–168):
```swift
                try? messageStore.insertChatMessagePair(userMessage, fallbackMessage)
```

**Rationale:** either both messages persist or neither does.

**Acceptance criteria:**
- `DatabaseService.insertChatMessagePair` exists and uses `BEGIN`/`COMMIT`/`ROLLBACK`.
- `ChatViewModelTests.testChatHistoryPersisted` still passes (mock store appends both via the protocol default → `savedMessages.count == 2`).
- New test (`P4-T4`, `testPairInsertRollsBackOnFailure`): insert message A; then call `insertChatMessagePair(B, A2)` where `A2.id == A.id` (duplicate PRIMARY KEY → second insert fails). Expect the call to throw AND that `B` is **not** present (rolled back).

---

### P1-T3 — Schema version + ordered migrations
**Depends on:** P0-T6.
**File:** `Training/Training/DatabaseService.swift`.
**Problem:** `createTables()` is `CREATE TABLE IF NOT EXISTS` only (lines 29–62); there is no way to evolve the schema.

**Change:** Use SQLite's `PRAGMA user_version` as the schema version and apply ordered migrations after `createTables()`.

1. Add helpers:
```swift
    private func userVersion() -> Int {
        let stmt = try? prepare("PRAGMA user_version")
        defer { if let stmt { sqlite3_finalize(stmt) } }
        guard let stmt, sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func setUserVersion(_ v: Int) {
        sqlite3_exec(db, "PRAGMA user_version = \(v);", nil, nil, nil)
    }

    /// Ordered migrations. `createTables()` establishes the v1 baseline; add
    /// future (version, SQL) pairs here and they run once, in order.
    private func migrate() throws {
        let migrations: [(version: Int, sql: String)] = [
            // Example for the future (do NOT add now unless you actually change schema):
            // (2, "ALTER TABLE activity_log ADD COLUMN source TEXT;"),
        ]
        var current = userVersion()
        if current == 0 { current = 1; setUserVersion(1) } // baseline created by createTables()
        for m in migrations where m.version > current {
            try exec(m.sql)
            setUserVersion(m.version)
            current = m.version
        }
    }
```

2. Call it in `init` right after the pragmas added in `P0-T6`:
```swift
        try createTables()
        sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        try migrate()
```
   (These run inside `init`, which is before any `sync` wrapping is needed; `exec`/`prepare` are the private non-locking helpers, so calling them directly here is correct.)

**Rationale:** provides a real, ordered upgrade path instead of relying only on `IF NOT EXISTS`.

**Acceptance criteria:**
- Opening a fresh `:memory:` DB leaves `PRAGMA user_version` == 1 (baseline). Add test `testSchemaVersionInitialized` in `P4-T4` that opens a DB and asserts version ≥ 1 via a tiny test-only accessor OR indirectly (see note below).
- `swift test` DB tests still pass.
> Safe default / note: to keep the version testable without exposing internals, add a `func schemaVersion() throws -> Int` public method that returns `try sync { userVersion() }`. If you prefer not to widen the API, mark `testSchemaVersionInitialized` as covering only "migrations do not crash on repeated open" (open the same file DB twice; second open must not error).

---

### P1-T4 — Guard against duplicate `call_id` overwriting results
**Depends on:** P0-T7.
**File:** `Training/Training/Tools/ToolProtocol.swift`.
**Problem:** `ToolRegistry.execute` (lines 82–91) stores results in a `[String: String]` keyed by `callId`. If the planner emits two tools with the same `call_id`, the second silently overwrites the first.
**Policy (locked): keep the FIRST result for a given `call_id`; skip later duplicates.**

**Change:**
```swift
    func execute(_ planned: [PlannedTool]) async -> [String: String] {
        var results: [String: String] = [:]
        for p in planned {
            if results[p.callId] != nil { continue } // duplicate call_id: keep first, skip
            let tool = queue.sync { tools[p.name] }
            if let t = tool {
                results[p.callId] = await t.execute(params: p.params)
            }
        }
        return results
    }
```

**Rationale:** deterministic, collision-safe tool results; pairs with the prompt fix in `P2-T3`.

**Acceptance criteria:**
- New test (`P4-T4`, `testDuplicateCallIdKeepsFirst`): register a tool, execute two `PlannedTool`s with the same `callId` but params that would produce different outputs; assert exactly one entry for that `callId` and that it equals the first tool's output.

---

### P1-T5 — Fix `AnyCodable` decimal truncation
**Depends on:** P0-T1.
**File:** `Training/Training/Tools/ToolProtocol.swift`.
**Problem:** `AnyCodable.init(from:)` (lines 51–57) does `String(Int(d))` for `Double`, so `5.5` becomes `"5"`.

**Change:** Replace the `Double` branch (line 55) and add a formatter:
```swift
struct AnyCodable: Codable {
    let stringValue: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { stringValue = s }
        else if let i = try? c.decode(Int.self) { stringValue = String(i) }
        else if let d = try? c.decode(Double.self) { stringValue = AnyCodable.format(d) }
        else { stringValue = "" }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stringValue)
    }
    /// Whole numbers render without a decimal ("5"); fractions keep precision ("5.5").
    static func format(_ d: Double) -> String {
        if d.rounded() == d && abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }
}
```

**Rationale:** preserve fractional params (e.g. `distance_km: 5.5`) coming from the planner as numbers.

**Acceptance criteria:**
- New test (`P4-T4`, `testAnyCodableDecimal`): decode JSON values `5.5` → `"5.5"`, `5.0` → `"5"`, `7` → `"7"`, `"abc"` → `"abc"`.

---

## 6. PHASE 2 — LLM / NETWORKING ROBUSTNESS

### P2-T1 — Selective, cancellation-aware retries with backoff + jitter
**Depends on:** P0-T3.
**File:** `Training/Training/DeepSeekClient.swift`.
**Problem:** `chat` (lines 46–56) retries **every** error once with a fixed 2s sleep — it retries 4xx (pointless) and is not cancellation-aware.

**Change:** Replace `chat`'s retry loop and add classifiers:
```swift
    func chat(
        model: String = "deepseek-chat",
        messages: [[String: String]],
        temperature: Double = 0.7,
        maxTokens: Int = 2000
    ) async throws -> (content: String, usage: TokenUsage) {
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                return try await performRequest(model: model, messages: messages, temperature: temperature, maxTokens: maxTokens)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard Self.isRetryable(error), attempt < maxAttempts - 1 else { throw error }
                let backoff = pow(2.0, Double(attempt)) * 0.5   // 0.5s, 1.0s
                let jitter = Double.random(in: 0...0.25)
                try await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
            }
        }
        throw lastError ?? DeepSeekClientError.invalidResponse
    }

    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case DeepSeekClientError.httpError(let status, _):
            return status >= 500            // server errors only; never 4xx
        case DeepSeekClientError.networkError(let underlying):
            if let urlError = underlying as? URLError {
                switch urlError.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                     .cannotConnectToHost, .dnsLookupFailed:
                    return true
                default:
                    return false
                }
            }
            return false
        default:
            return false                    // decode errors, missingContent, invalidResponse: not retryable
        }
    }
```

**Rationale:** only transient failures are retried; cancellation propagates; backoff avoids hammering.

**Acceptance criteria:**
- `DeepSeekClientTests` all still pass:
  - `testTimeout`: `URLError.timedOut` is retryable → after attempts it throws `DeepSeekClientError.networkError(.timedOut)`. ✅ (Note: this test now takes ~1.5s+jitter due to backoff — acceptable.)
  - `testParseErrorResponse` (401): 4xx not retryable → throws immediately. ✅
  - `testParseMalformedJSON`, `testParseMissingContent`: not retryable → throw immediately. ✅
- Optional new test (`P4-T4`, `testNoRetryOn4xx`): use a handler that increments a counter and returns 400; assert the handler was invoked exactly once.

---

### P2-T2 — Harden `extractJSON`
**Depends on:** P0-T1.
**File:** `Training/Training/ChatViewModel.swift`.
**Problem:** `extractJSON` (lines 306–322) strips ``` ```json ``` fences then takes first `{` … last `}`. It breaks when there is prose containing braces, multiple JSON blocks, or braces inside string values.

**Change:** Replace `extractJSON` with a brace-matching scanner that (a) removes code fences if present, then (b) returns the first **balanced** `{ … }` object, respecting string literals and escapes:
```swift
    private func extractJSON(from text: String) -> String {
        // 1) Prefer content inside a fenced code block if present.
        var s = text
        if let fenceStart = s.range(of: "```") {
            var body = String(s[fenceStart.upperBound...])
            if body.hasPrefix("json") { body = String(body.dropFirst(4)) }
            if let fenceEnd = body.range(of: "```") {
                body = String(body[..<fenceEnd.lowerBound])
            }
            s = body
        }
        // 2) Find the first balanced JSON object, ignoring braces inside strings.
        let chars = Array(s)
        var start: Int? = nil
        var depth = 0
        var inString = false
        var escaped = false
        for i in 0..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let st = start {
                        return String(chars[st...i])
                    }
                }
            default: break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

**Rationale:** correctly extract the JSON object even with surrounding prose, fences, nested braces, or braces inside strings.

**Acceptance criteria:**
- New tests (`P4-T4`, `ExtractJSONTests` — since `extractJSON` is `private`, test it indirectly through the planner path OR temporarily expose it; **safe default: add an internal static mirror** `static func _extractJSONForTesting(_ text: String) -> String` that calls the same logic, and test that). Cases:
  - plain `{"a":"b"}` → `{"a":"b"}`
  - ` ```json\n{"a":1}\n``` ` → `{"a":1}`
  - `here is data: {"a":{"b":2}} thanks` → `{"a":{"b":2}}`
  - `{"note":"has } brace in string"}` → returns the whole object (brace inside string not treated as close).
- Existing planner tests still pass (`ChatViewModelTests`, `Batch3Tests.testPlannerRetriesOnParseFailure` where the first response `"not json"` yields no object → nil → retry).

---

### P2-T3 — Fix the malformed planner example JSON in the prompt
**Depends on:** P0-T1.
**File:** `Training/Training/PromptBuilder.swift`.
**Problem:** `plannerSystemPrompt()` embeds an example (lines 57–66) that is invalid JSON: the line for `sum7` (line 60) has **no trailing comma** before the next object, and `sum7` is **duplicated**. This teaches the model bad patterns.

**Change:** Replace the example `tools` array (lines 58–65) with valid JSON that has unique `call_id`s and correct commas:
```swift
        {
          "tools": [
            {"call_id": "rhr7", "name": "get_metric", "params": {"metric": "rhr", "range": "7"}},
            {"call_id": "hrv7", "name": "get_metric", "params": {"metric": "hrv", "range": "7"}},
            {"call_id": "sum7", "name": "get_daily_summary", "params": {"range": "7"}}
          ],
          "prompt_template": "RHR 7日：{rhr7}\\nHRV 7日：{hrv7}\\n每日摘要：\\n{sum7}\\n\\n请分析恢复状态。"
        }
```
(Keep the surrounding Chinese instruction text unchanged.)

**Rationale:** the in-prompt example must be valid, comma-correct, and use unique `call_id`s.

**Acceptance criteria:**
- New test (`P4-T4`, `testPlannerExampleJSONIsValid`): extract the `{ … }` example from `PromptBuilder.plannerSystemPrompt()` (use the same balanced-scan as `P2-T2`, or a simple first-`{`/last-`}` slice on the example region) and confirm `JSONSerialization.jsonObject(with:)` succeeds and the `tools` array has 3 entries with unique `call_id`s.
- `PromptBuilderTests` still pass.

---

### P2-T4 — Injection-safe, deterministic `render`
**Depends on:** P0-T1.
**File:** `Training/Training/PromptBuilder.swift`.
**Problem:** `render` (lines 112–118) iterates the `data` dictionary and does a global `replacingOccurrences` per key. Dictionary iteration order is **non-deterministic**, and if one tool's output text contains another key's placeholder (e.g. tool output literally contains `"{sum7}"`), a later pass can substitute into already-inserted text (prompt injection via tool output / user text).

**Change:** Replace `render` with a single left-to-right pass that only substitutes placeholders found in the *template* and inserts values **verbatim** (never re-scans inserted text):
```swift
    static func render(_ template: String, with data: [String: String]) -> String {
        var result = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "{", let close = chars[(i+1)...].firstIndex(of: "}") {
                let key = String(chars[(i+1)..<close])
                if let value = data[key] {
                    result += value          // inserted verbatim, not re-scanned
                    i = close + 1
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }
```

**Rationale:** deterministic (single pass, order-independent) and injection-safe (tool/user text inserted into the template cannot itself trigger further substitution). Unknown placeholders are left as-is.

**Acceptance criteria:**
- Existing `PromptBuilderTests` all still pass:
  - `testRenderReplacesPlaceholders`, `testRenderMissingKeyLeavesPlaceholder`, `testRenderMultiplePlaceholders`.
- New tests (`P4-T4`):
  - `testRenderDoesNotReSubstitute`: `render("{a}{b}", ["a": "{b}", "b": "X"])` → `"{b}X"` (the `{b}` produced by `a` is NOT replaced).
  - `testRenderOrderIndependent`: same inputs produce the same output across repeated calls.

---

### P2-T5 — Preserve decode error detail; make `usage` optional
**Depends on:** P0-T3 (same file as P2-T1; do after P2-T1).
**File:** `Training/Training/DeepSeekClient.swift`.
**Problem:** decode failures collapse to `.invalidResponse` (line 96), losing detail; and `DeepSeekResponse.usage` (line 19) is required, so a response missing `usage` fails to decode.

**Change:**

1. Add an error case with the underlying error. In `enum DeepSeekClientError` (lines 3–8) add:
```swift
    case decodingError(Error)
```

2. Make `usage` optional. In `struct DeepSeekResponse` (line 19): `let usage: TokenUsage?`.

3. In `performRequest`, replace the decode catch (lines 93–97) and the return (lines 99–103):
```swift
        let decoder = JSONDecoder()
        let result: DeepSeekResponse
        do {
            result = try decoder.decode(DeepSeekResponse.self, from: data)
        } catch {
            throw DeepSeekClientError.decodingError(error)
        }

        guard let content = result.choices.first?.message.content else {
            throw DeepSeekClientError.missingContent
        }
        let usage = result.usage ?? TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        return (content, usage)
```

**Rationale:** keep the real decoding error for debugging; tolerate responses without `usage`.

**Acceptance criteria:**
- `DeepSeekClientTests.testParseMalformedJSON` still passes (`error is DeepSeekClientError` — now `.decodingError`). ✅
- `testParseMissingContent` still passes (choices empty → `.missingContent`; usage present decodes fine). ✅
- `testParseSuccessResponse` still passes (usage present → real values). ✅
- New test (`P4-T4`, `testUsageOptionalDefaultsZero`): a 200 body with `choices` but no `usage` returns content and `usage.totalTokens == 0` (does not throw).

---

## 7. PHASE 3 — PERFORMANCE / CORRECTNESS / UX

### P3-T1 — Replace per-day HealthKit loops with `HKStatisticsCollectionQuery` (RISKIEST)
**Depends on:** P0-T1.
**Files:** `Training/Training/HealthDataService.swift` (add helper), `Training/Training/Tools/MetricTool.swift`, `Training/Training/Tools/TableTools.swift` (`DailySummaryTool`), `Training/Training/Tools/RecoveryTool.swift`, `Training/Training/ContentView.swift`.
**Problem:** several places issue one `HKStatisticsQuery` **per day** in a loop (up to 365 iterations): `MetricTool.execute` (lines 54–61) and `queryTable` (lines 79–85); `DailySummaryTool.execute` (lines 94–102); `RecoveryTool.metricRange` (lines 40–48); `ContentView.metricAvg` (lines 127–138). This is slow and hammers HealthKit.

**Change:** Add ONE shared helper that runs a single collection query bucketed by day, then refactor callers to use it.

1. In `HealthDataService`, add:
```swift
    /// One HKStatisticsCollectionQuery bucketed per day for the last `days` days.
    /// Returns [startOfDay: convertedValue]. Uses `options` (.cumulativeSum → sum, else average).
    static func dailyStatistics(
        store: HKHealthStore,
        id: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        days: Int,
        converter: @escaping (Double) -> Double
    ) async -> [Date: Double] {
        guard HKHealthStore.isHealthDataAvailable(), days > 0 else { return [:] }
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: Date())                       // today 00:00
        guard let anchor = cal.date(byAdding: .day, value: -days, to: endDay) else { return [:] }
        let qty = HKQuantityType(id)
        let unit = HealthDataService.unit(for: id)
        let predicate = HKQuery.predicateForSamples(withStart: anchor, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { (cont: CheckedContinuation<[Date: Double], Never>) in
            let q = HKStatisticsCollectionQuery(
                quantityType: qty,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, results, _ in
                var out: [Date: Double] = [:]
                results?.enumerateStatistics(from: anchor, to: Date()) { stat, _ in
                    let quantity = options.contains(.cumulativeSum) ? stat.sumQuantity() : stat.averageQuantity()
                    if let quantity {
                        out[cal.startOfDay(for: stat.startDate)] = converter(quantity.doubleValue(for: unit))
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }
```

2. Refactor callers to build their per-day arrays from the dictionary instead of looping queries. For each caller, produce the list of the last `range` days (`startOfDay(today) - d` for `d in 1...range`), look each up in the returned dictionary (missing day = skip), then compute exactly as before (average / trend / table rows). Concretely:
   - `MetricTool.execute` summary branch (lines 54–73): call `let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: opts, days: range, converter: converter)`, then `let values = (1...range).compactMap { byDay[cal.startOfDay(for: cal.date(byAdding: .day, value: -$0, to: Date())!)] }` and keep the existing avg/trend logic.
   - `MetricTool.queryTable` (lines 76–87): same dictionary; build rows for each day that has a value.
   - `MetricTool` single-day (range == 1) path: you may keep `queryDay` for the single-day case OR call `dailyStatistics(days: 1)`. **Safe default: keep the existing single-day `queryDay` for range == 1** (it is only one query).
   - `DailySummaryTool.execute` (lines 84–104): call `dailyStatistics` once **per metric key** (4 metrics → 4 collection queries instead of 4×range single queries), then assemble the table rows per day from the 4 dictionaries.
   - `RecoveryTool.metricRange` (lines 40–48): `let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: .discreteAverage, days: days, converter: { $0 }); let vals = Array(byDay.values); return vals.isEmpty ? nil : vals.reduce(0,+)/Double(vals.count)`.
   - `ContentView.metricAvg` (lines 127–138): same pattern as `RecoveryTool.metricRange` using `healthStore`.
   Delete the now-unused `queryDay`/`metricOnDay` helpers **only if** no caller references them after refactor (MetricTool may keep `queryDay` for the range==1 path — then keep it).

**Rationale:** one bucketed query per metric instead of N per-day queries.

> ⚠️ RISK & SAFE DEFAULT: This is the highest-risk task and **cannot be validated headlessly** (HealthKit returns no data on the test host, and `swift test` does not exercise it). Validate by `swift build` (must compile) and by the author running the app. **If the collection-query refactor for any single caller proves troublesome, it is acceptable to leave that caller's per-day loop as-is** for this personal app — correctness first. Prioritize converting `DailySummaryTool` and `MetricTool` (the up-to-365 offenders). Do not block later tasks on this one.

**Acceptance criteria:**
- `HealthDataService.dailyStatistics(...)` exists and compiles.
- At least `MetricTool` and `DailySummaryTool` use it (no per-day `HKStatisticsQuery` loop remains in those two summary/table paths, except the explicitly-allowed range==1 single-day path).
- `swift build` succeeds; `swift test` still passes (no HealthKit tests regressed; the pure `HealthDataService.unit/convert/woType/sleepStage` tests still pass).

---

### P3-T2 — HealthKit availability + do not discard authorization result
**Depends on:** P0-T4.
**File:** `Training/Training/ContentView.swift`.
**Problem:** `requestHealthAuth` (lines 76–91) calls `requestAuthorization(toShare:read:) { _, _ in cont.resume() }` — it throws away both the `success` flag and the `error`. Also queries run even when health data is unavailable.

**Change:**

1. Capture the auth result. Add a `@State private var healthError: String?` near the other `@State` vars (top of `ContentView`). Rewrite the completion:
```swift
    private func requestHealthAuth() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthError = "健康数据在此设备不可用"
            return
        }
        let types: Set<HKSampleType> = [ /* ... unchanged set ... */ ]
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            healthStore.requestAuthorization(toShare: [], read: types) { success, error in
                if let error { AppLog.health.error("HealthKit auth failed: \(error.localizedDescription)") }
                else if !success { AppLog.health.notice("HealthKit auth not granted") }
                cont.resume()
            }
        }
    }
```
   (`AppLog` comes from `P4-T1`; if you do `P3-T2` before `P4-T1`, temporarily leave the two `AppLog` lines as `// TODO(P4-T1): log`. Safe default either way.)

2. Guard the status-bar refresh. At the top of `refreshStatusBar()` (line 93):
```swift
        guard HKHealthStore.isHealthDataAvailable() else { return }
```

**Rationale:** don't silently ignore auth failures; degrade gracefully when HealthKit is unavailable.

**Acceptance criteria:**
- `requestHealthAuth` checks `HKHealthStore.isHealthDataAvailable()` and inspects `success`/`error` (they are no longer both `_`).
- `refreshStatusBar` early-returns when health data is unavailable.
- `swift build` succeeds.

---

### P3-T3 — Cost: fix `reconcile` semantics + fix `CostBarView` duplicated value
**Depends on:** P0-T4, P0-T8.
**Files:** `Training/Training/CostTracker.swift`, `Training/Training/ChatViewModel.swift`, `Training/Training/ContentView.swift`, and test `Tests/TrainingAppTests/CostTrackerTests.swift`.
**Scope reminder (per adjusted instructions):** pricing stays a simple, hand-editable constant — **do NOT** add cache-hit/miss tiers and **do NOT** research real prices. Keep `PriceConfig` structure and its current numbers (leave a `// TODO(author): set real DeepSeek prices` comment). Only the two fixes below.

**Problem A — `reconcile` compares incomparable quantities.** `reconcile(localTotal:apiBalance:)` (lines 95–99) does `abs(apiBalance - localTotal)`. But `localTotal` is **cumulative spend** and `apiBalance` is **remaining prepaid balance** — subtracting them is meaningless. (`reconcile` is currently only called by tests, not by app UI.)

**Change A — redesign to a meaningful check:** compare the *drop* in API balance between two readings against the local spend recorded between those readings.
```swift
struct ReconciliationResult {
    let flagged: Bool
    let diff: Double            // |actualDrop - expectedDrop|
    let expectedDrop: Double    // = localSpend
    let actualDrop: Double      // = previousBalance - currentBalance
}

// in CostTracker:
    /// Compares how much the API balance dropped against how much we think we spent.
    /// `localSpend` is the spend accumulated between the two balance readings.
    func reconcile(previousBalance: Double, currentBalance: Double, localSpend: Double, tolerance: Double = 0.10) -> ReconciliationResult {
        let actualDrop = previousBalance - currentBalance
        let diff = abs(actualDrop - localSpend)
        return ReconciliationResult(flagged: diff > tolerance, diff: diff, expectedDrop: localSpend, actualDrop: actualDrop)
    }
```
Update the two `CostTrackerTests` reconcile tests (lines 64–82) to the new semantics:
```swift
    @Test("reconciliation within tolerance: balance drop ≈ local spend")
    func testReconciliationWithinThreshold() {
        let tracker = CostTracker(config: .default)
        // spent 0.20; balance went 10.00 -> 9.85 (dropped 0.15). diff 0.05 < 0.10 -> not flagged
        let result = tracker.reconcile(previousBalance: 10.00, currentBalance: 9.85, localSpend: 0.20)
        #expect(result.flagged == false)
        #expect(abs(result.diff - 0.05) < 0.000001)
    }

    @Test("reconciliation over tolerance: balance drop deviates from local spend")
    func testReconciliationOverThreshold() {
        let tracker = CostTracker(config: .default)
        // spent 0.20; balance dropped 0.35. diff 0.15 > 0.10 -> flagged
        let result = tracker.reconcile(previousBalance: 10.00, currentBalance: 9.65, localSpend: 0.20)
        #expect(result.flagged == true)
        #expect(abs(result.diff - 0.15) < 0.000001)
    }
```
> Note: `reconcile` has no UI caller; this keeps it a correct, self-contained utility. Do NOT wire it into the UI (out of scope).

**Problem B — `CostBarView` shows the same number for "本次" and "会话".** `ContentView` builds `CostBarView(sessionCost: viewModel.sessionCost, totalSessionCost: viewModel.sessionCost, accumulatedCost: viewModel.accumulatedCost)` (line 60) — `viewModel.sessionCost` is passed to BOTH the "本次" (this turn) and "会话" (session) fields (`CostBarView` labels at lines 160–162).

**Change B — track a per-turn cost separately:**
1. In `ChatViewModel`, add a per-turn cost property near `sessionCost` (line 57). Also **remove the debug `didSet` print** on `sessionCost` while here:
```swift
    var sessionCost: Double = 0
    private(set) var lastTurnCost: Double = 0
```
2. In `sendMessage`, set `lastTurnCost` when the assistant reply is produced. Right after `let executorCost = costTracker.accumulate(usage: executorUsage)` and `sessionCost = costTracker.sessionCost()` (lines 222–223), add:
```swift
            lastTurnCost = plannerResponse.cost + executorCost
```
3. In `ContentView` line 60, pass the per-turn cost to the first field:
```swift
            CostBarView(sessionCost: viewModel.lastTurnCost, totalSessionCost: viewModel.sessionCost, accumulatedCost: viewModel.accumulatedCost)
```

**Rationale:** "本次" = last turn's cost, "会话" = cumulative session cost, "累计" = all-time — three distinct, correct numbers.

**Acceptance criteria:**
- `CostTracker.reconcile` uses the new signature; the two updated reconcile tests pass; all other `CostTrackerTests` still pass.
- `ChatViewModel` has `lastTurnCost`; `sessionCost` no longer has a `didSet { print(...) }`.
- `CostBarView` receives `viewModel.lastTurnCost` for the first field and `viewModel.sessionCost` for the second.
- New test (`P4-T4`, `testLastTurnVsSessionCostDiffer`): with a mock returning known token usage, run `sendMessage` twice; assert `lastTurnCost` equals a single turn's cost while `sessionCost` (via the injected `CostTracker.sessionCost()`) equals the sum of both turns (so they differ after the 2nd turn).

---

### P3-T4 — Clean dead / duplicated code
**Depends on:** P0-T1 (recovery-score part shares the `HealthDataService` area with P3-T2).
**Files:** `Training/Training/HealthDataService.swift`, `Training/Training/Tools/RecoveryTool.swift`, `Training/Training/ContentView.swift`, `Training/Training/Tools/MetricTool.swift`, (optional) `Training/Training/Tools/TableTools.swift`.

**Change:**

1. **De-duplicate the recovery-score formula.** The identical formula exists in `RecoveryTool.execute` (lines 17–19) and `ContentView.refreshStatusBar` (lines 107–109). Add one pure function to `HealthDataService`:
```swift
    /// Recovery score 0–100 from today's vs baseline HRV/RHR. Higher = better recovered.
    static func recoveryScore(hrvToday: Double, hrvBaseline: Double, rhrToday: Double, rhrBaseline: Double) -> Int {
        let hrvScore = max(0, min(100, 50 + ((hrvToday - hrvBaseline) / hrvBaseline) / 0.30 * 50))
        let rhrScore = max(0, min(100, 50 + ((rhrBaseline - rhrToday) / rhrBaseline) / 0.10 * 50))
        return Int(0.6 * hrvScore + 0.4 * rhrScore)
    }
```
   - In `RecoveryTool.execute`, replace lines 17–19 with `let score = HealthDataService.recoveryScore(hrvToday: ht, hrvBaseline: hb, rhrToday: rt, rhrBaseline: rb)`.
   - In `ContentView.refreshStatusBar`, replace lines 107–109 with `let score = HealthDataService.recoveryScore(hrvToday: ht, hrvBaseline: hBase, rhrToday: Double(rt), rhrBaseline: rBase)`.

2. **Remove dead locals in `MetricTool.querySingle`** (lines 89–95): it computes `s` and `e` (start/end of today) then never uses them — it just calls `queryDay(...today...)`. Delete the unused `guard let s = …, let e = …` and keep:
```swift
    private func querySingle(id: HKQuantityTypeIdentifier, opts: HKStatisticsOptions, converter: @escaping (Double) -> Double) async -> Double? {
        await queryDay(id: id, opts: opts, date: Date(), converter: converter)
    }
```

3. **`sleepStage`: KEEP as-is.** The prior review called `HealthDataService.sleepStage` (lines 34–44) "dead with contradictory numbering," but its mapping (0=InBed,1=Asleep,2=Awake,3=Core,4=Deep,5=REM) actually **matches** `HKCategoryValueSleepAnalysis` and is consistent with the raw ints used in `SleepTableTool` (TableTools.swift lines 30–34). It is also covered by 7 tests in `HealthDataServiceTests`. **Do NOT delete it** (that would break those tests for no benefit).
   - OPTIONAL (low priority, only if trivial): make `SleepTableTool`'s `switch s.value` (lines 29–35) call `HealthDataService.sleepStage(s.value)` to remove the magic numbers. **Safe default: skip this** — it is cosmetic.

**Rationale:** remove genuine duplication (recovery formula) and dead locals; keep tested, correct code.

**Acceptance criteria:**
- `HealthDataService.recoveryScore(...)` exists; both `RecoveryTool` and `ContentView` call it (no inline duplicate formula remains — `grep -n "0.6 \* hrvScore" Training/Training` appears only inside `HealthDataService.recoveryScore`).
- `MetricTool.querySingle` has no unused `s`/`e`.
- New test (`P4-T4`, `testRecoveryScore`): assert e.g. `recoveryScore(hrvToday: hb, hrvBaseline: hb, rhrToday: rb, rhrBaseline: rb) == 50` when today==baseline (score 50 both → 50), and monotonic direction (higher HRV → higher score).
- `HealthDataServiceTests` (sleepStage etc.) still pass.

---

## 8. PHASE 4 — MINIMAL HYGIENE & TESTS

### P4-T1 — Route logging through `os.Logger`; remove print noise
**Depends on:** best done after code is stable (end of Phase 3).
**Files:** add logging to `Training/Training/`; edit every file that calls `print(`.
**Problem:** scattered `print(...)` debug statements and a `sessionCost` `didSet` print.

**Change:**

1. Add a tiny logger wrapper. Create the type inside an existing file is fine, but preferred: add it to `Models.swift` (bottom) or a new small file `Training/Training/AppLog.swift`. **Safe default: put it at the bottom of `Models.swift`** to avoid touching the Xcode project's file set (the synchronized group picks up new files automatically, but adding to an existing file is zero-risk):
```swift
import os

enum AppLog {
    static let chat = Logger(subsystem: "Training", category: "chat")
    static let db = Logger(subsystem: "Training", category: "db")
    static let net = Logger(subsystem: "Training", category: "net")
    static let health = Logger(subsystem: "Training", category: "health")
    static let tools = Logger(subsystem: "Training", category: "tools")
}
```

2. Remove or replace every `print(`:
   - `ChatViewModel.swift`: the `sessionCost didSet { print(...) }` is already removed in `P3-T3`. Remove/replace the remaining prints (lines ~145, 221, 242, 244, 249, 251, 256, 268, 284, 294). Replace genuinely useful ones with `AppLog.chat.debug("...")`/`.error("...")`; delete pure noise (e.g. the `[MESSAGE] Messages count` chatter). At minimum, the DB save failure catch (P1-T2) should be `AppLog.db.error("save failed: \(error.localizedDescription)")`.
   - `TableTools.swift`: `SleepTableTool` line 25 `print("[SLEEP] ...")` → `AppLog.health.debug(...)` or delete.

**Rationale:** structured logging, no console spam, no accidental cost-value leakage via `didSet`.

**Acceptance criteria:**
- `grep -R "print(" Training/Training` returns nothing (0 occurrences).
- No `didSet { print` anywhere.
- `swift build` and `swift test` pass.

---

### P4-T2 — Remove the hardcoded test-string message filter
**Depends on:** P0-T8 (already satisfies most of this).
**File:** `Training/Training/ChatViewModel.swift`.
**Problem:** the old `convenience init()` filtered out specific debug seed strings (`"帮我看看恢复情况"`, `"过去5天睡眠怎么样"`, `"15天步态"`, `"过去7天步态情况"`, `"hi"`, and the `"请记录以下活动："` prefix) — debugging residue (was at line 107).

**Change:** `P0-T8` already moved history loading into `bootstrap()` and loads `messages = recent.reversed()` with **no content filter**. Confirm no such hardcoded string filter remains anywhere.

**Rationale:** production code must not special-case the author's debug phrases.

**Acceptance criteria:**
- `grep -R "帮我看看恢复情况\|过去5天睡眠\|15天步态\|过去7天步态\|请记录以下活动" Training/Training/ChatViewModel.swift` returns nothing in the history-loading path (the `logActivityViaPlanner` prefix `"请记录以下活动："` used when *sending* a record request may remain — that is a real prefix, not a filter; only the *filter* in history loading must be gone).
- `swift test` passes.

---

### P4-T3 — Fix/rename the mis-named `StreamingTests`
**Depends on:** none.
**File:** `Tests/TrainingAppTests/StreamingTests.swift`.
**Problem:** the suite is named "Streaming message" / `StreamingMessageTests` but it tests the **planner→executor flow**, not SSE streaming. There is no streaming in the app.

**Change:**
1. Rename the file to `PlannerFlowTests.swift`.
2. Rename the suite: `@Suite("Streaming message")` → `@Suite("Planner flow (non-streaming)")`, and `struct StreamingMessageTests` → `struct PlannerFlowTests`.
3. Add a top-of-file comment:
```swift
// NOTE: SSE streaming is a Future Phase (NOT implemented now). These tests cover the
// non-streaming planner→executor request/response flow. See SPEC_REFACTOR.md.
```

**Rationale:** the test name must reflect what it tests; record that streaming is deferred.

**Acceptance criteria:**
- File is `Tests/TrainingAppTests/PlannerFlowTests.swift`; suite/struct renamed; tests still pass.
- `grep -R "StreamingMessageTests" Tests` returns nothing.

> Future Phase (not now): SSE streaming of the executor response could be added later by switching `DeepSeekClient.performRequest` to `session.bytes(for:)` and parsing `data:` lines, plus streaming partial content into a message. **Do not implement now.**

---

### P4-T4 — Add / adjust tests
**Depends on:** the features each test targets (noted inline).
**File:** add tests to the relevant existing test files (or new files under `Tests/TrainingAppTests/`).

Add the following tests (each references the task that implements the behavior). Use the Swift Testing framework style already used in the repo (`@Test`, `#expect`, `@Suite`).

1. **DB crash paths** (needs P0-T5) — in `DatabaseServiceTests.swift`, `testMalformedRowIsSkippedNotCrash`: open `:memory:`, use `exec`-level insert of a `chat_message` row with an invalid `id` (`"not-a-uuid"`) and a valid one; `queryRecentMessages` returns only the valid row and does not crash. (If you cannot insert a bad row via the public API, insert via a raw SQL helper in the test using a fresh `DatabaseService` extended with a test-only `execRaw`; **safe default**: add `func execRawForTesting(_ sql: String) throws { try sync { try exec(sql) } }` to `DatabaseService`.)
2. **activity_log unification** (needs P1-T1) — `testManualActivitiesReadsActivityLog`: insert an `ActivityLog(type: "Soccer", …)`; `ManualActivitiesTool(store: db).execute(params: [:])` output contains `"Soccer"`.
3. **`extractJSON` edge cases** (needs P2-T2) — see the four cases in `P2-T2` (use the internal `_extractJSONForTesting` mirror).
4. **Recovery score** (needs P3-T4) — see `P3-T4` acceptance.
5. **render determinism / injection** (needs P2-T4) — see `P2-T4` acceptance.
6. **Planner example JSON validity** (needs P2-T3) — see `P2-T3` acceptance.
7. **Reconcile new semantics** (needs P3-T3) — the two updated reconcile tests (already specified in `P3-T3`).
8. **AnyCodable decimal** (needs P1-T5) — see `P1-T5` acceptance.
9. **Duplicate call_id** (needs P1-T4) — see `P1-T4` acceptance.
10. **Pair insert rollback** (needs P1-T2) — see `P1-T2` acceptance.
11. **lastTurn vs session cost** (needs P3-T3) — see `P3-T3` acceptance.
12. **Optional usage default** (needs P2-T5) — see `P2-T5` acceptance.

**Adjust pre-existing broken test — `Batch2Tests.testManualRecordingWritesActivity`** (needs P1-T1). This test calls `sendMessage("今天踢了60分钟")` and expects a "已记录/活动" message, but `sendMessage` runs the planner→executor chat flow, not activity recording (recording is `logActivityViaPlanner`, used by `RecordModeView`). Replace it so it tests the real recording path against `activity_log`:
```swift
    @Test("manual recording writes to activity_log")
    func testManualRecordingWritesActivity() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let tool = LogActivityTool(store: db)
        _ = await tool.execute(params: ["type": "Soccer", "date": "2026-07-06", "duration_min": "60"])
        let logs = try db.queryAllActivities()
        #expect(logs.contains { $0.type == "Soccer" })
    }
```

**Acceptance criteria:**
- All new/adjusted tests pass.
- `swift test` is **fully green** (every test in `Tests/TrainingAppTests/**` passes). This is the final gate for the whole refactor.

---

## 9. UNCERTAINTIES & SAFE DEFAULTS (consolidated)

The author locked "no web research"; the following rely on existing knowledge. Where noted, a safe default keeps you unblocked:

1. **`deepseek-reasoner` parameter support (P0-T3):** best knowledge — `temperature`, `top_p`, `presence_penalty`, `frequency_penalty` are accepted-but-ignored; `logprobs`/`top_logprobs` error; no function-calling/JSON-mode; responses include `reasoning_content` (this app ignores it and does no multi-turn pass-back, which is fine). **Safe default implemented:** omit `temperature` only for models containing `"reasoner"`; keep `max_tokens`. If the author later confirms different behavior, it is a one-line change. Harmless if slightly wrong (the API ignores the param anyway).
2. **`deepseek-reasoner` model lifetime:** this is a legacy alias and may be retired by the provider. Because all model selection funnels through `AppConfig.deepSeekModel`, switching models later is one line. **No action now** (locked decision = `deepseek-reasoner`).
3. **`max_tokens` sizing for reasoning models (P0-T3):** reasoning tokens count against the budget; the planner's 1000 *might* truncate. **Safe default: leave current values;** raise planner `maxTokens` only if truncation is observed.
4. **Pricing values (P3-T3):** left as the current `PriceConfig` constants with a `// TODO(author)` comment. No cache tiers, no research (per instructions).
5. **`HKStatisticsCollectionQuery` refactor (P3-T1):** cannot be validated headlessly. **Safe default: convert the big offenders (`DailySummaryTool`, `MetricTool`); if any single caller is troublesome, leaving its per-day loop is acceptable.** Do not block other work.
6. **Testing `private` funcs (`extractJSON`):** **safe default** — add an `internal static` `_…ForTesting` mirror rather than changing access levels broadly.
7. **Schema-version test (P1-T3):** if you don't want to widen the public API, **safe default** is to test "reopen doesn't crash / re-run migrations" instead of asserting the exact version number.
8. **Git nested repo (P0-T1):** removing `Training/.git` is optional; **safe default is to leave it** — building/testing/editing are unaffected because there is still exactly one copy of each file.

---

## 10. QUICK CHECKLIST (tick as you go)

- [x] P0-T1 single tree (delete `Sources/`, repoint `Package.swift`) — `swift build` OK
- [x] P0-T2 tests compile (`swift test` runs)
- [x] P0-T3 `AppConfig.deepSeekModel` = `deepseek-reasoner`, temperature omitted for reasoner
- [x] P0-T4 `@State var viewModel`
- [x] P0-T5 no force-unwraps in DB mappers
- [x] P0-T6 DB serial queue + busy_timeout + WAL
- [x] P0-T7 no `ToolRegistry.shared`
- [x] P0-T8 cheap init + `bootstrap()`, single DB connection into tools
- [x] P1-T1 `ManualActivitiesTool` reads `activity_log`
- [x] P1-T2 `insertChatMessagePair` transaction
- [x] P1-T3 `PRAGMA user_version` migrations
- [x] P1-T4 duplicate `call_id` kept-first
- [x] P1-T5 `AnyCodable` decimals preserved
- [x] P2-T1 selective retries + cancellation + backoff
- [x] P2-T2 hardened `extractJSON`
- [x] P2-T3 valid planner example JSON
- [x] P2-T4 deterministic injection-safe `render`
- [x] P2-T5 `decodingError` + optional `usage`
- [x] P3-T1 `HKStatisticsCollectionQuery` (big offenders)
- [x] P3-T2 `isHealthDataAvailable` + auth result handled
- [x] P3-T3 `reconcile` redesigned + `CostBarView` distinct values
- [x] P3-T4 shared `recoveryScore`, dead locals removed, `sleepStage` kept
- [ ] P4-T1 << remaining `os.Logger`, no `print(`
- [x] P4-T2 no hardcoded message filter
- [x] P4-T3 `PlannerFlowTests`
- [ ] P4-T4 << remaining all new/adjusted tests green — `swift test` fully passes
