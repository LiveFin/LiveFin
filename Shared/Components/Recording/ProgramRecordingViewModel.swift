//
//  ProgramRecordingViewModel.swift
//  LiveFin
//
//  Created by KPGamingz on 7/6/26.
//

import SwiftUI
import UserNotifications

// A global coalescing cache to prevent EPG grids from DDoSing the server
// when hundreds of ProgramRecordingViewModels are initialized simultaneously.
actor JellyfinTimerCache {
    static let shared = JellyfinTimerCache()
    
    private var cachedTimers: [JFTimer]?
    private var cachedTimersDate: Date?
    private var fetchTimersTask: Task<[JFTimer], Error>?
    
    private var cachedSeriesTimers: [JFSeriesTimer]?
    private var cachedSeriesTimersDate: Date?
    private var fetchSeriesTimersTask: Task<[JFSeriesTimer], Error>?
    
    func getTimers(baseURL: String, token: String) async throws -> [JFTimer] {
        if let cached = cachedTimers, let date = cachedTimersDate, Date().timeIntervalSince(date) < 30 {
            return cached
        }
        
        if let existingTask = fetchTimersTask {
            return try await existingTask.value
        }
        
        let task = Task<[JFTimer], Error> {
            guard let url = URL(string: baseURL)?.appendingPathComponent("LiveTv/Timers") else { return [] }
            var req = URLRequest(url: url)
            req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            let (data, _) = try await URLSession.shared.data(for: req)
            struct JFQueryResult: Decodable { let Items: [JFTimer] }
            return try JSONDecoder().decode(JFQueryResult.self, from: data).Items
        }
        
        fetchTimersTask = task
        
        do {
            let items = try await task.value
            cachedTimers = items
            cachedTimersDate = Date()
            fetchTimersTask = nil
            return items
        } catch {
            fetchTimersTask = nil
            throw error
        }
    }
    
    func getSeriesTimers(baseURL: String, token: String) async throws -> [JFSeriesTimer] {
        if let cached = cachedSeriesTimers, let date = cachedSeriesTimersDate, Date().timeIntervalSince(date) < 30 {
            return cached
        }
        
        if let existingTask = fetchSeriesTimersTask {
            return try await existingTask.value
        }
        
        let task = Task<[JFSeriesTimer], Error> {
            guard let url = URL(string: baseURL)?.appendingPathComponent("LiveTv/SeriesTimers") else { return [] }
            var req = URLRequest(url: url)
            req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            let (data, _) = try await URLSession.shared.data(for: req)
            struct JFQueryResult: Decodable { let Items: [JFSeriesTimer] }
            return try JSONDecoder().decode(JFQueryResult.self, from: data).Items
        }
        
        fetchSeriesTimersTask = task
        
        do {
            let items = try await task.value
            cachedSeriesTimers = items
            cachedSeriesTimersDate = Date()
            fetchSeriesTimersTask = nil
            return items
        } catch {
            fetchSeriesTimersTask = nil
            throw error
        }
    }
    
    func clearCache() {
        cachedTimers = nil
        cachedSeriesTimers = nil
    }
}

@MainActor
final class ProgramRecordingViewModel: ObservableObject {
    @Published var configuration = RecordingConfiguration()
    @Published var notificationConfig = NotificationConfiguration()
    @Published var isScheduling: Bool = false
    @Published var activeTimerId: String? = nil
    @Published var activeTimerIsSeries: Bool = false
    @Published var errorMessage: String? = nil
    @Published var hasNotificationScheduled: Bool = false
    
    let program: JFProgram
    private let appState: AppState
    
    var isRecordingScheduled: Bool {
        activeTimerId != nil
    }
    
    init(program: JFProgram, appState: AppState) {
        self.program = program
        self.appState = appState
        
        // Fetch existing notification state immediately upon view model creation
        checkPendingNotifications()
        
        Task {
            await checkExistingTimer()
        }
    }
    
    // MARK: - API Helpers
    
    private var cleanBaseURL: String {
        let raw = appState.serverURL
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
    
    // MARK: - DVR API Interactions
    
    private func checkExistingTimer() async {
        guard !appState.serverURL.isEmpty else { return }
        
        do {
            let timers = try await JellyfinTimerCache.shared.getTimers(baseURL: cleanBaseURL, token: appState.accessToken)
            if let existing = timers.first(where: { $0.ProgramId == program.id }) {
                self.activeTimerId = existing.Id
                self.activeTimerIsSeries = false
            }
        } catch {
            print("Failed to check existing single timer: \(error)")
        }
        
        // Also check series timers since a series timer acts globally
        if program.isSeries {
            do {
                let sTimers = try await JellyfinTimerCache.shared.getSeriesTimers(baseURL: cleanBaseURL, token: appState.accessToken)
                if let existing = sTimers.first(where: { $0.Name == program.name || $0.Name == program.seriesName }) {
                    self.activeTimerId = existing.Id
                    self.activeTimerIsSeries = true
                }
            } catch {
                print("Failed to check existing series timer: \(error)")
            }
        }
    }
    
    func scheduleRecording() async {
        guard !appState.serverURL.isEmpty else { return }
        isScheduling = true
        errorMessage = nil
        
        let isLikelySeries = program.isSeries || (program.seriesId != nil && !program.seriesId!.isEmpty) || (program.seriesName != nil && !program.seriesName!.isEmpty)
        let isSeries = configuration.isSeriesTimer && isLikelySeries
        
        var payloadToPost: [String: Any]?
        
        // Fetch default server templates right before posting
        let defaultEndpoint = isSeries ? "/LiveTv/SeriesTimers/Defaults" : "/LiveTv/Timers/Defaults"
        let defaultUrl = URL(string: cleanBaseURL)?.appendingPathComponent(defaultEndpoint)
        var comps = URLComponents(url: defaultUrl!, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "programId", value: program.id)]
        
        if let finalDefaultUrl = comps?.url {
            var defaultReq = URLRequest(url: finalDefaultUrl)
            defaultReq.httpMethod = "GET"
            if !appState.accessToken.isEmpty { defaultReq.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            
            if let (defaultData, defaultResp) = try? await URLSession.shared.data(for: defaultReq),
               let httpResp = defaultResp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) {
                payloadToPost = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
            }
        }
        
        guard var payload = payloadToPost else {
            errorMessage = "Failed to fetch recording template from server."
            isScheduling = false
            return
        }
        
        payload["PrePaddingSeconds"] = configuration.prePaddingSeconds
        payload["PostPaddingSeconds"] = configuration.postPaddingSeconds
        
        if isSeries {
            payload["RecordAnyTime"] = configuration.recordAnyTime
            payload["RecordAnyChannel"] = configuration.recordAnyChannel
            payload["RecordNewOnly"] = configuration.recordNewOnly
        }
        
        let postEndpoint = isSeries ? "/LiveTv/SeriesTimers" : "/LiveTv/Timers"
        guard let url = URL(string: cleanBaseURL)?.appendingPathComponent(postEndpoint) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !appState.accessToken.isEmpty {
            request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                errorMessage = "Invalid network response."
                isScheduling = false
                return
            }
            
            if !(200...299).contains(httpResponse.statusCode) {
                let errStr = String(data: data, encoding: .utf8) ?? "No details provided"
                let cleanErr = errStr.prefix(150).trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = "Server Error (\(httpResponse.statusCode)): \(cleanErr.isEmpty ? "Check Jellyfin logs" : cleanErr)"
                isScheduling = false
                return
            }
            
            if let timerResponse = try? JSONDecoder().decode(JFTimerResponse.self, from: data) {
                self.activeTimerId = timerResponse.Id
                self.activeTimerIsSeries = isSeries
            } else {
                self.activeTimerId = "scheduled_unknown_id"
                self.activeTimerIsSeries = isSeries
            }
            
            Task { await JellyfinTimerCache.shared.clearCache() }
            
            // Use notificationConfig to decide whether to schedule a finish notification
            if self.activeTimerId != nil && notificationConfig.notifyOnFinish == true {
                await scheduleFinishNotification()
            }
            
        } catch {
            errorMessage = "A network error occurred: \(error.localizedDescription)"
        }
        
        isScheduling = false
    }
    
    func cancelRecording() async {
        guard let timerId = activeTimerId, !appState.serverURL.isEmpty else { return }
        isScheduling = true
        
        let endpoint = activeTimerIsSeries ? "/LiveTv/SeriesTimers/\(timerId)" : "/LiveTv/Timers/\(timerId)"
        guard let url = URL(string: cleanBaseURL)?.appendingPathComponent(endpoint) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if !appState.accessToken.isEmpty {
            request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    self.activeTimerId = nil
                    Task { await JellyfinTimerCache.shared.clearCache() }
                } else {
                    let errStr = String(data: data, encoding: .utf8) ?? ""
                    errorMessage = "Failed to cancel (\(httpResponse.statusCode)): \(errStr)"
                }
            }
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
        }
        
        isScheduling = false
    }
    
    // MARK: - Device Local Notifications
    
    func scheduleLocalNotification() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                print("Notification permissions rejected: \(error)")
                return
            }
        }
        
        // Ensure accurate state mapping for Live items
        let isLive: Bool = {
            guard let start = program.startDate else { return false }
            let runTime = program.runTimeSeconds > 0 ? program.runTimeSeconds : 3600
            let end = program.endDate ?? start.addingTimeInterval(runTime)
            return start <= Date() && Date() <= end
        }()
        let isLikelySeries = program.isSeries || (program.seriesId != nil && !program.seriesId!.isEmpty) || (program.seriesName != nil && !program.seriesName!.isEmpty)
        
        if isLive && isLikelySeries {
            notificationConfig.notifySeries = true
        }
        
        if notificationConfig.notifySeries {
            var allUpcoming: [JFProgram] = [self.program]
            
            let isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
            let nowStr = isoPlain.string(from: Date())
            let endStr = isoPlain.string(from: Calendar.current.date(byAdding: .day, value: 14, to: Date())!)
            
            let sname = (program.seriesName?.isEmpty == false) ? program.seriesName! : program.name
            
            // 1. Fetch via /Items for robust EPG Searching across channels
            if let url = URL(string: cleanBaseURL)?.appendingPathComponent("Items") {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.queryItems = [
                    URLQueryItem(name: "IncludeItemTypes", value: "Program"),
                    URLQueryItem(name: "Recursive", value: "true"),
                    URLQueryItem(name: "MinStartDate", value: nowStr),
                    URLQueryItem(name: "MaxStartDate", value: endStr),
                    URLQueryItem(name: "SearchTerm", value: sname),
                    URLQueryItem(name: "Limit", value: "100"),
                    URLQueryItem(name: "Fields", value: "SeriesId,IsNew,ChannelName")
                ]
                
                if let reqUrl = comps?.url {
                    var req = URLRequest(url: reqUrl)
                    if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
                    if let (data, resp) = try? await URLSession.shared.data(for: req),
                       let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 {
                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let items = obj["Items"] as? [[String: Any]] {
                            allUpcoming.append(contentsOf: items.compactMap { JFProgram(json: $0) })
                        }
                    }
                }
            }
            
            // 2. Fetch via /LiveTv/Programs explicitly by ID fallback
            if let sid = program.seriesId, !sid.isEmpty {
                if let url = URL(string: cleanBaseURL)?.appendingPathComponent("LiveTv/Programs") {
                    var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    comps?.queryItems = [
                        URLQueryItem(name: "SeriesId", value: sid),
                        URLQueryItem(name: "MinStartDate", value: nowStr),
                        URLQueryItem(name: "MaxStartDate", value: endStr),
                        URLQueryItem(name: "Limit", value: "100"),
                        URLQueryItem(name: "Fields", value: "SeriesId,IsNew,ChannelName")
                    ]
                    
                    if let reqUrl = comps?.url {
                        var req = URLRequest(url: reqUrl)
                        if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
                        if let (data, resp) = try? await URLSession.shared.data(for: req),
                           let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 {
                            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let items = obj["Items"] as? [[String: Any]] {
                                allUpcoming.append(contentsOf: items.compactMap { JFProgram(json: $0) })
                            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                                allUpcoming.append(contentsOf: arr.compactMap { JFProgram(json: $0) })
                            }
                        }
                    }
                }
            }
            
            // Deduplicate, filter out past airings, and sort chronologically
            var seen = Set<String>()
            let uniqueUpcoming = allUpcoming.filter { p in
                guard let start = p.startDate, start > Date() else { return false }
                return seen.insert(p.id).inserted
            }.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            
            // Limit to max 15 episodes so we don't accidentally hit the iOS 64 pending notification hard limit
            let cappedUpcoming = uniqueUpcoming.prefix(15)
            
            for p in cappedUpcoming {
                await scheduleSingleNotification(for: p, center: center)
            }
        } else {
            await scheduleSingleNotification(for: self.program, center: center)
        }
        
        Task { @MainActor in
            self.hasNotificationScheduled = true
            // Check state again shortly after to ensure accurate reflection of what was scheduled
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.checkPendingNotifications()
        }
    }
    
    private func scheduleSingleNotification(for p: JFProgram, center: UNUserNotificationCenter) async {
        if notificationConfig.notifyNewEpisodesOnly && !(p.isNew ?? false) {
            return
        }
        
        guard let startDate = p.startDate else { return }
        let initialBuffer = notificationConfig.notificationBufferSeconds
        
        // 1. Calculate intervals for periodical notifications
        var intervalsToSchedule: [Int] = [initialBuffer]
        
        // Only schedule periodic reminders if buffer > 0 and repeat is ON
        if notificationConfig.repeatNotification && initialBuffer > 0 {
            // Standard steps: 1 hr, 30 min, 15 min, 5 min, 0 min (Start Time)
            let periodicSteps = [3600, 1800, 900, 300, 0]
            
            for step in periodicSteps {
                if step < initialBuffer && !intervalsToSchedule.contains(step) {
                    intervalsToSchedule.append(step)
                }
            }
        }
        
        // 2. Loop and schedule a discrete notification for each interval
        for interval in intervalsToSchedule {
            let triggerDate = startDate.addingTimeInterval(-Double(interval))
            
            guard triggerDate > Date() else { continue }
            
            let content = UNMutableNotificationContent()
            let minutes = interval / 60
            var timeString = ""
            
            if minutes >= 1440 {
                let days = minutes / 1440
                timeString = "\(days) day\(days > 1 ? "s" : "")"
            } else if minutes >= 60 {
                let hours = minutes / 60
                timeString = "\(hours) hour\(hours > 1 ? "s" : "")"
            } else {
                timeString = "\(minutes) minute\(minutes > 1 ? "s" : "")"
            }
            
            let isRightNow = (interval == 0)
            let isNew = (p.isNew ?? false)
            
            if isRightNow {
                content.title = isNew ? "New Episode Premiere" : "Starting Now"
                content.body = "\(p.name) starts right now on \(p.channelName ?? "Live TV")."
            } else {
                content.title = isNew ? "Upcoming Premiere" : "Starting Soon"
                content.body = "\(p.name) starts in \(timeString) on \(p.channelName ?? "Live TV")."
            }
            
            content.sound = .default
            
            // Attach payload for deep-linking when tapped
            content.userInfo = [
                "action": isRightNow ? "play" : "open",
                "programId": p.id
            ]
            
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            
            let seriesPart = p.seriesId ?? "none"
            let sname = p.seriesName ?? p.name
            let safeName = sname.isEmpty ? "unknown" : sname.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unknown"
            
            // Append an `isseries_true/false` tag into the unique ID so we can reliably re-hydrate the toggle state later
            let isSeriesMode = notificationConfig.notifySeries ? "true" : "false"
            
            // Append `_offset_\(interval)` so iOS treats each step as a unique notification
            let uniqueId = "reminder_\(p.id)_isseries_\(isSeriesMode)_series_\(seriesPart)_name_\(safeName)_offset_\(interval)"
            
            let request = UNNotificationRequest(identifier: uniqueId, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
    
    func scheduleFinishNotification() async {
        var finishTriggerDate: Date? = nil
        
        // Fetch accurate Timer EndDate from the server to handle EPG alterations
        if let timerId = activeTimerId, !activeTimerIsSeries, !appState.serverURL.isEmpty {
            let url = URL(string: cleanBaseURL)?.appendingPathComponent("LiveTv/Timers/\(timerId)")
            var request = URLRequest(url: url!)
            request.httpMethod = "GET"
            if !appState.accessToken.isEmpty { request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            
            do {
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let timer = try? JSONDecoder().decode(JFTimer.self, from: data) {
                    finishTriggerDate = timer.parsedEndDate
                }
            }
        }
        
        // Fallback to manual offset logic if fetch failed or if it's a series master timer
        if finishTriggerDate == nil, let startDate = program.startDate {
            let runTime = program.runTimeSeconds > 0 ? program.runTimeSeconds : 3600 // fallback
            let endDate = program.endDate ?? startDate.addingTimeInterval(runTime)
            finishTriggerDate = endDate.addingTimeInterval(Double(configuration.postPaddingSeconds))
        }
        
        guard let triggerDate = finishTriggerDate, triggerDate > Date() else { return }
        
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Recording Finished"
        content.body = "Your recording for \(program.name) has completed."
        content.sound = .default
        
        let finishComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: finishComponents, repeats: false)
        
        let uniqueId = "recording_finish_\(program.id)_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: uniqueId, content: content, trigger: trigger)
        try? await center.add(request)
    }
    
    func cancelLocalNotification() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self = self else { return }
            
            let pid = self.program.id
            let sid = self.program.seriesId
            let sname = (self.program.seriesName ?? self.program.name)
            let safeName = sname.isEmpty ? "unknown" : sname.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unknown"
            
            // Only cancel the entire series if the user left the toggle ON
            let cancelSeries = self.notificationConfig.notifySeries
            
            let matchingIds = requests.filter { req in
                // Always cancel reminders specific to THIS exact episode
                if req.identifier.contains("reminder_\(pid)") { return true }
                
                // If they instructed us to remove the series, scoop up the rest
                if cancelSeries {
                    if let validSid = sid, !validSid.isEmpty, req.identifier.contains("series_\(validSid)") { return true }
                    if req.identifier.contains("name_\(safeName)") && safeName != "unknown" { return true }
                }
                
                return false
            }.map { $0.identifier }
            
            center.removePendingNotificationRequests(withIdentifiers: matchingIds)
            
            // Re-verify actual state slightly after deletion to avoid ghost UI
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.checkPendingNotifications()
            }
        }
        // Optimistically set to false
        self.hasNotificationScheduled = false
    }
    
    func checkPendingNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
            guard let self = self else { return }
            
            let pid = self.program.id
            let sid = self.program.seriesId
            let sname = (self.program.seriesName ?? self.program.name)
            let safeName = sname.isEmpty ? "unknown" : sname.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unknown"
            
            var hasThisProgram = false
            var hasSeriesScheduled = false
            
            for req in requests {
                let isSeriesReminder = req.identifier.contains("isseries_true")
                
                if req.identifier.contains("reminder_\(pid)") {
                    hasThisProgram = true
                    if isSeriesReminder { hasSeriesScheduled = true }
                } else {
                    // Check if other episodes of this series are scheduled to correctly restore the UI toggles
                    if let validSid = sid, !validSid.isEmpty, req.identifier.contains("series_\(validSid)") {
                        if isSeriesReminder { hasSeriesScheduled = true }
                    } else if req.identifier.contains("name_\(safeName)") && safeName != "unknown" {
                        if isSeriesReminder { hasSeriesScheduled = true }
                    }
                }
            }
            
            Task { @MainActor in
                // CRITICAL FIX: Only light up the Bell if THIS SPECIFIC episode is pending.
                // Previously, it lit up for any episode in the series, prompting users to click
                // 'Remove Reminder' on a live episode, unintentionally wiping all future episodes.
                self.hasNotificationScheduled = hasThisProgram
                
                // If any episode in the series is scheduled as a series reminder, reflect that in the toggle UI
                if hasSeriesScheduled {
                    self.notificationConfig.notifySeries = true
                }
            }
        }
    }
}
