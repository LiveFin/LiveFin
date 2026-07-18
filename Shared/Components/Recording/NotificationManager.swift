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
