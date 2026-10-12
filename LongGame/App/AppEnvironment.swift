import CloudKit
import Coach
import CoreData
import Foundation
import HealthIngest
import Models
import Observation
import SwiftData

#if os(iOS)
import UIKit
#endif

/// App-wide state: which store is open, where health data comes from, and sync status.
@Observable
final class AppEnvironment {
    enum StoreKind: Equatable {
        case cloudKit(containerID: String)
        case localOnly(reason: String)
        case fixture
    }

    enum HealthState: Equatable {
        /// This device only shows data synced from the iPhone.
        case viewer
        case needsAuthorization
        case idle
        case syncing
        case synced(Date)
        case failed
    }

    /// Nil until the store can be opened. The store uses complete file protection, so
    /// a launch in the background while the device is locked has to wait for an unlock.
    private(set) var container: ModelContainer?
    private(set) var storeKind: StoreKind = .localOnly(reason: "Store is not open yet")
    /// Nil on devices that only view synced data.
    let healthSource: (any HealthDataSource)?

    let coach = CoachSession()
    let reminder = WeeklyReminder()
    /// Whether this device is signed in to iCloud; nil until checked or when not syncing.
    private(set) var iCloudAccountAvailable: Bool?

    private(set) var healthState: HealthState = .viewer
    private(set) var lastSyncEvent: Date?
    private(set) var lastSyncFailed = false
    /// How far the current Health sync has got; nil when none is running.
    private(set) var healthStep: SyncStep?
    /// Whether the running Health sync should be shown. Quick background top-ups stay
    /// quiet; a first import, a manual sync or anything slow is announced.
    private(set) var showsHealthSync = false
    /// iCloud imports and exports in progress, by event.
    private var cloudImports: Set<UUID> = []
    private var cloudExports: Set<UUID> = []
    var isImportingFromICloud: Bool { !cloudImports.isEmpty }
    var isExportingToICloud: Bool { !cloudExports.isEmpty }
    private(set) var lastImport: Date?
    private(set) var lastExport: Date?
    /// A manual iCloud sync is in progress. The store is closed and reopened for it, so
    /// the screens are replaced by a progress view until it is back.
    private(set) var isForcingCloudSync = false
    /// How the last manual sync ended, for Settings.
    private(set) var forcedSyncOutcome: ForcedSyncOutcome?

    enum ForcedSyncOutcome: Equatable {
        case finished(Date)
        /// The store reopened but iCloud did not report back in time.
        case noReply
        case failed
    }
    /// True until Health has been read successfully once on this device.
    var isFirstHealthSync: Bool { healthSource != nil && syncState.date(for: .lastDailySync) == nil }

    private let syncState: UserDefaultsSyncStateStore
    private var didStart = false
    private var isObservingHealth = false

    private static let minimumSyncInterval: TimeInterval = 60

    /// The simulator has no health data, so it always runs on the fixture. Debug builds
    /// on a device or Mac can opt in with the `-fixture` launch argument.
    static var usesFixture: Bool {
        #if targetEnvironment(simulator)
        true
        #elseif DEBUG
        ProcessInfo.processInfo.arguments.contains("-fixture")
        #else
        false
        #endif
    }

    init() {
        if Self.usesFixture {
            // `-slowFixture` rehearses a long first import so the progress states can be seen.
            let isSlow = ProcessInfo.processInfo.arguments.contains("-slowFixture")
            healthSource = try? FixtureHealthDataSource(workoutDelay: isSlow ? .milliseconds(120) : .zero)
            syncState = UserDefaultsSyncStateStore(prefix: "fixture.")
        } else {
            healthSource = Self.makeHealthKitSource()
            syncState = UserDefaultsSyncStateStore()
        }
        healthState = healthSource == nil ? .viewer : .idle
        openStore()
    }

    /// The iPhone is the ingest device. iPad has a health store too, but two devices
    /// ingesting the same workouts would create duplicates before sync catches up.
    private static func makeHealthKitSource() -> (any HealthDataSource)? {
        #if os(iOS)
        let source = HealthKitDataSource()
        return UIDevice.current.userInterfaceIdiom == .phone && source.isAvailable ? source : nil
        #else
        return nil
        #endif
    }

    // MARK: Store

    #if DEBUG
    private var didInitializeSchema = false
    #endif

    /// Opens the store if it is not open yet. Fails quietly while the device is locked.
    private func openStore() {
        guard container == nil else { return }
        if Self.usesFixture {
            // Fixture data goes in its own store that never syncs.
            if let opened = try? LongGameStore.makeContainer(mode: .local(name: "Fixture")) {
                container = opened
                storeKind = .fixture
            }
            return
        }
        let containerID = Bundle.main.object(forInfoDictionaryKey: "LGCloudKitContainer") as? String ?? ""
        #if DEBUG
        // `-initializeCloudKitSchema` writes the whole schema to CloudKit Development,
        // ready to deploy to Production. See the README.
        if !containerID.isEmpty, !didInitializeSchema,
            ProcessInfo.processInfo.arguments.contains("-initializeCloudKitSchema")
        {
            didInitializeSchema = true
            do {
                try LongGameStore.initializeCloudKitSchema(containerID: containerID)
                print("CloudKit schema initialized for \(containerID)")
            } catch {
                print("CloudKit schema initialization failed: \(error)")
            }
        }
        #endif
        if !containerID.isEmpty,
            let opened = try? LongGameStore.makeContainer(mode: .cloudKit(containerID: containerID))
        {
            container = opened
            storeKind = .cloudKit(containerID: containerID)
        } else if let opened = try? LongGameStore.makeContainer(mode: .local(name: "LongGame")) {
            container = opened
            storeKind = .localOnly(
                reason: containerID.isEmpty ? "No iCloud container configured" : "iCloud store could not be opened")
        }
    }

    private var isProtectedDataAvailable: Bool {
        #if os(iOS)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    // MARK: Lifecycle

    /// Called at launch (including background launches) and whenever the app becomes active.
    func activate() async {
        openStore()
        guard container != nil else { return }

        if !didStart {
            didStart = true
            Task { await observeSyncEvents() }
        }

        // Days saved by earlier builds as local midnights become day stamps.
        if let container { _ = try? DayStampRepair.run(in: container.mainContext) }
        // A new day can turn yesterday's unmatched sessions into missed ones.
        reconcilePlan()
        coach.refreshKey()
        await reminder.refresh()
        await checkICloudAccount()

        guard let healthSource else { return }
        if await healthSource.needsAuthorization() {
            healthState = .needsAuthorization
            return
        }
        await observeHealth()
        await syncHealth()
    }

    /// Shows the Health permission sheet, then reads everything.
    func connectHealth() async {
        guard let healthSource else { return }
        do {
            try await healthSource.requestAuthorization()
        } catch {
            healthState = .failed
            return
        }
        await observeHealth()
        await syncHealth(force: true)
    }

    /// Observer queries have to be registered on every launch for background delivery to work.
    private func observeHealth() async {
        guard let healthSource, !isObservingHealth else { return }
        isObservingHealth = true
        do {
            try await healthSource.observeWorkouts { [weak self] in
                await self?.syncHealth(force: true)
            }
        } catch {
            isObservingHealth = false
        }
    }

    func syncHealth(force: Bool = false) async {
        guard let healthSource, healthState != .syncing, healthState != .needsAuthorization else { return }
        if !force, case .synced(let date) = healthState, Date().timeIntervalSince(date) < Self.minimumSyncInterval {
            return
        }
        // Neither Health nor the store can be read while the device is locked; the next
        // activation picks the changes up.
        openStore()
        guard let container, isProtectedDataAvailable else { return }

        healthState = .syncing
        healthStep = .readingProfile
        showsHealthSync = force || isFirstHealthSync
        // A sync that turns out to be slow is announced after a moment.
        let reveal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { self?.showsHealthSync = true }
        }
        let syncState = syncState
        // Created off the main actor so the ingest work stays off it too.
        let result = await Task.detached { [weak self] in
            try await HealthIngestor(modelContainer: container).sync(from: healthSource, state: syncState) { step in
                Task { @MainActor in
                    // Late updates from a finished sync are ignored.
                    if self?.healthState == .syncing { self?.healthStep = step }
                }
            }
        }.result
        reveal.cancel()
        switch result {
        case .success: healthState = .synced(Date())
        case .failure: healthState = .failed
        }
        healthStep = nil
        showsHealthSync = false
        if Self.usesFixture { SamplePlan.seedIfNeeded(in: container.mainContext) }
        reconcilePlan()
        if Self.usesFixture {
            SamplePlan.seedReviewIfNeeded(in: container.mainContext)
            SamplePlan.seedDraftIfNeeded(in: container.mainContext)
            SamplePlan.seedConversationIfNeeded(in: container.mainContext)
        }
    }

    /// Re-runs matching, compliance and training load after anything that could change them.
    func reconcilePlan() {
        guard let container else { return }
        _ = try? PlanReconciler.reconcile(in: container.mainContext)
        // Load comes second: an unmeasured workout's estimate depends on its matched session.
        _ = try? LoadRecalculator.recalculate(in: container.mainContext)
        // Whatever edit led here is saved now, which starts its upload to iCloud.
        saveChanges()
    }

    /// Forgets how far ingest has read, so the next sync re-reads the whole backfill window.
    func resyncHealth() async {
        syncState.reset()
        await syncHealth(force: true)
    }

    private func checkICloudAccount() async {
        guard case .cloudKit(let containerID) = storeKind else { return }
        let status = try? await CKContainer(identifier: containerID).accountStatus()
        iCloudAccountAvailable = status.map { $0 == .available }
    }

    private func observeSyncEvents() async {
        guard case .cloudKit = storeKind else { return }
        struct Update: Sendable {
            let id: UUID
            let type: NSPersistentCloudKitContainer.EventType
            let finished: Date?
            let succeeded: Bool
        }
        let notifications = NotificationCenter.default.notifications(
            named: NSPersistentCloudKitContainer.eventChangedNotification
        ).compactMap { notification -> Update? in
            let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            guard let event = notification.userInfo?[key] as? NSPersistentCloudKitContainer.Event else { return nil }
            return Update(id: event.identifier, type: event.type, finished: event.endDate, succeeded: event.succeeded)
        }
        for await update in notifications {
            if let finished = update.finished {
                cloudImports.remove(update.id)
                cloudExports.remove(update.id)
                lastSyncEvent = finished
                lastSyncFailed = !update.succeeded
                if update.succeeded {
                    if update.type == .import { lastImport = finished }
                    if update.type == .export { lastExport = finished }
                }
            } else if update.type == .import {
                cloudImports.insert(update.id)
            } else if update.type == .export {
                cloudExports.insert(update.id)
            }
        }
    }

    // MARK: iCloud sync

    /// Writes any unsaved edits to the store now. iCloud uploads follow a save, so this
    /// is what makes a change start syncing straight away instead of at the next autosave.
    func saveChanges() {
        guard let context = container?.mainContext, context.hasChanges else { return }
        try? context.save()
    }

    var canForceCloudSync: Bool {
        // Sample-data mode has no iCloud, but can still rehearse closing and reopening the store.
        if case .localOnly = storeKind { return false }
        return container != nil && !isForcingCloudSync && healthState != .syncing && !coach.isBusy
    }

    /// Pushes local changes and pulls whatever iCloud has. Apple offers no "sync now" call
    /// for this kind of store, so this does what a relaunch does: saves, closes the store
    /// and opens it again, which makes it check iCloud in both directions.
    func forceCloudSync() async {
        guard canForceCloudSync else { return }
        isForcingCloudSync = true
        forcedSyncOutcome = nil
        let started = Date()
        saveChanges()
        // Let go of the store. The screens holding it are swapped for a progress view,
        // and a moment is allowed for them to release it before it is opened again.
        container = nil
        try? await Task.sleep(for: .milliseconds(600))
        openStore()
        guard container != nil else {
            forcedSyncOutcome = .failed
            isForcingCloudSync = false
            return
        }
        guard case .cloudKit = storeKind else {
            forcedSyncOutcome = .finished(Date())
            isForcingCloudSync = false
            reconcilePlan()
            return
        }
        // The import runs in the background once the store is open; wait for it to report.
        var outcome = ForcedSyncOutcome.noReply
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if let lastImport, lastImport >= started {
                outcome = .finished(lastImport)
                break
            }
            if lastSyncFailed, let lastSyncEvent, lastSyncEvent >= started {
                outcome = .failed
                break
            }
        }
        forcedSyncOutcome = outcome
        isForcingCloudSync = false
        reconcilePlan()
    }

    // MARK: Activity

    /// What the app is busy with right now, in words, for the banner shown on every tab.
    var activities: [AppActivity] {
        var list: [AppActivity] = []
        if healthState == .syncing, showsHealthSync {
            list.append(AppActivity(id: "health", text: healthSyncText))
        }
        if isImportingFromICloud, !isForcingCloudSync {
            list.append(AppActivity(id: "icloud", text: "Getting your data from iCloud…"))
        }
        if let text = coach.activityText {
            list.append(AppActivity(id: "coach", text: text))
        }
        return list
    }

    var healthSyncText: String {
        let source = storeKind == .fixture ? "sample data" : "Apple Health"
        switch healthStep {
        case .readingWorkouts(let done, let total) where total > 0:
            return "Importing workouts from \(source): \(done) of \(total)"
        case .readingWorkouts:
            return isFirstHealthSync ? "Finding your last 90 days of workouts…" : "Checking \(source) for new workouts…"
        case .readingDailyMetrics:
            return "Reading sleep, heart rate and recovery…"
        case .saving:
            return "Saving…"
        case .readingProfile, nil:
            return "Reading \(source)…"
        }
    }
}

struct AppActivity: Identifiable, Equatable {
    let id: String
    let text: String
}
