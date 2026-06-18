import SwiftUI
import BackgroundTasks

@main
struct LiveFinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
        
    @StateObject private var appState = AppState()
    
    // Background refresh identifier - must also be added to Info.plist
    private static let bgRefreshIdentifier = "com.livefin.app.epgrefresh"
    private static var bgRegistered = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onAppear {
                    // One-time BGTask registration; do not capture `self` in init to avoid escaping capture of a mutating self
                    if !Self.bgRegistered {
                        Self.bgRegistered = true
                        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgRefreshIdentifier, using: nil) { rawTask in
                            guard let task = rawTask as? BGAppRefreshTask else {
                                rawTask.setTaskCompleted(success: false)
                                return
                            }

                            // Schedule next
                            let req = BGAppRefreshTaskRequest(identifier: Self.bgRefreshIdentifier)
                            req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
                            do { try BGTaskScheduler.shared.submit(req) } catch { print("Failed to resubmit BGAppRefresh: \(error)") }

                            // Perform the refresh using AppState (captured reference type)
                            let queue = OperationQueue()
                            queue.maxConcurrentOperationCount = 1
                            let op = BlockOperation {
                                let sem = DispatchSemaphore(value: 0)
                                Task {
                                    await appState.performBackgroundEPGRefresh()
                                    sem.signal()
                                }
                                _ = sem.wait(timeout: .now() + 25)
                            }

                            task.expirationHandler = { queue.cancelAllOperations() }
                            op.completionBlock = { task.setTaskCompleted(success: !op.isCancelled) }
                            queue.addOperation(op)
                        }
                    }
                    scheduleBackgroundRefresh()
                }
                .onChange(of: scenePhase) { oldValue, newValue in
                    if newValue == .background {
                        scheduleBackgroundRefresh()
                        // Fallback: perform an immediate background refresh while we have execution time
                        Task {
                            await appState.performBackgroundEPGRefresh()
                        }
                    }
                }
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshIdentifier)
        // Prefer a refresh no earlier than 15 minutes from now; let the system optimize
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("BGAppRefresh scheduled: \(Self.bgRefreshIdentifier)")
        } catch {
            print("Failed to schedule BGAppRefresh: \(error)")
        }
    }

    // keep handleAppRefresh if needed elsewhere, but not required for registration now
    private func handleAppRefresh(task: BGAppRefreshTask) {
        // Schedule the next refresh
        scheduleBackgroundRefresh()

        // Create an operation or Task to perform refresh and notify completion
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let op = BlockOperation {
            // Call AppState's background refresh synchronously (Task) and wait up to a timeout
            let sem = DispatchSemaphore(value: 0)
            Task {
                await appState.performBackgroundEPGRefresh()
                sem.signal()
            }
            // Wait but respect system time constraints (cap here 25s)
            let _ = sem.wait(timeout: .now() + 25)
        }

        task.expirationHandler = {
            // Cancel the operation if task expired
            queue.cancelAllOperations()
        }

        op.completionBlock = {
            task.setTaskCompleted(success: !op.isCancelled)
        }

        queue.addOperation(op)
    }
}
