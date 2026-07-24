//
//  NotificationManager.swift
//  LiveFin
//
//  Created by KPGamingz on 7/15/26.
//

import Foundation
import UserNotifications

class NotificationManager: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let shared = NotificationManager()
    
    @Published var requestedProgramId: String? = nil
    @Published var autoPlayRequested: Bool = false

    // MARK: - Scheduling storage
    // Keyed by "group" (a series or program title) -> list of notification identifiers
    // we've scheduled for it, so "cancel all" doesn't need to guess what's pending.
    private let defaults = UserDefaults.standard
    private let groupsKey = "LiveFin.scheduledNotificationGroups"

    private var groups: [String: [String]] {
        get { defaults.dictionary(forKey: groupsKey) as? [String: [String]] ?? [:] }
        set { defaults.set(newValue, forKey: groupsKey) }
    }

    func pendingCount(for groupKey: String) -> Int {
        groups[groupKey]?.count ?? 0
    }

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Schedules one notification per upcoming airing. Re-running this for the same
    /// groupKey clears out anything previously scheduled first, so a guide refresh
    /// never leaves stale/duplicate reminders behind.
    @discardableResult
    func scheduleNotifications(
        for programs: [JFProgram],
        groupKey: String,
        config: NotificationConfiguration
    ) async -> Int {
        await requestAuthorizationIfNeeded()
        cancelAllNotifications(for: groupKey)

        let center = UNUserNotificationCenter.current()
        var scheduledIds: [String] = []

        for program in programs {
            guard let start = program.startDate else { continue }
            let fireDate = start.addingTimeInterval(-Double(config.notificationBufferSeconds))
            guard fireDate > Date() else { continue }
            if config.notifyNewEpisodesOnly, program.isNew != true { continue }

            let content = UNMutableNotificationContent()
            content.title = program.seriesName?.isEmpty == false ? program.seriesName! : program.name
            if let ep = program.episodeTitle, !ep.isEmpty, program.seriesName?.isEmpty == false {
                content.subtitle = ep
            }
            let minutes = config.notificationBufferSeconds / 60
            content.body = minutes > 0
                ? "Starts in \(minutes) min on \(program.channelName ?? "your channel")"
                : "Starting now on \(program.channelName ?? "your channel")"
            content.sound = .default
            content.userInfo = [
                "programId": program.itemId ?? program.id,
                "action": "view",
                "groupKey": groupKey
            ]

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

            // airingKey (id + channel + start timestamp) guarantees a distinct identifier
            // per airing, even for the same program repeating on the same channel.
            let identifier = "airing.\(program.airingKey)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            do {
                try await center.add(request)
                scheduledIds.append(identifier)
            } catch { continue }
        }

        var updated = groups
        updated[groupKey] = scheduledIds
        groups = updated
        return scheduledIds.count
    }

    /// Cancels every notification scheduled for this program/series in one shot.
    func cancelAllNotifications(for groupKey: String) {
        guard let ids = groups[groupKey], !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        var updated = groups
        updated.removeValue(forKey: groupKey)
        groups = updated
    }

    // Called when the user taps a notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        
        if let programId = userInfo["programId"] as? String,
           let action = userInfo["action"] as? String {
            
            DispatchQueue.main.async {
                self.requestedProgramId = programId
                self.autoPlayRequested = (action == "play")
            }
        }
        
        completionHandler()
    }
    
    // Allows notifications to show up as banners even if the app is currently in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
