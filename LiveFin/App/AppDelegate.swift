//
//  AppDelegate.swift
//  LiveFin
//
//  Created by KPGamingz on 4/12/25.
//

import UIKit

@objc(AppDelegate)
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    // Default to portrait for the rest of the app
    static var orientationLock = UIInterfaceOrientationMask.portrait {
        didSet {
            // Push to main thread to ensure UI layout cycle catches the update
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                
                // 1. Force the root view controller to re-evaluate supported orientations.
                // This makes iOS immediately call `supportedInterfaceOrientationsFor` below.
                windowScene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                
                // 2. Request the physical layout to snap to the new lock
                let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientationLock)
                windowScene.requestGeometryUpdate(preferences) { error in
                    print("[Orientation] Geometry update error: \(error.localizedDescription)")
                }
            }
        }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // This is the source of truth the OS checks
        return AppDelegate.orientationLock
    }
}
