import SwiftUI

struct ToolbarView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAbout = false

    // Dynamically check if the iOS app is running on a Mac (Catalyst or Apple Silicon)
    private var isRunningOnMac: Bool {
        if ProcessInfo.processInfo.isMacCatalystApp { return true }
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        }
        return false
    }

    var body: some View {
        Menu {
            Button(action: { showAbout = true }) {
                Label("About", systemImage: "info.circle")
            }
            Button(action: openDiscord) {
                Label {
                    Text("Discord")
                } icon: {
                    resizedDiscordIcon
                }
            }
            Button(role: .destructive, action: { appState.logout() }) {
                Label("Logout", systemImage: "person.crop.circle.badge.minus")
            }
        } label: { profileLabel }
        .sheet(isPresented: $showAbout) { AboutView() }
        .onAppear { ensureProfileLoadedIfNeeded() }
    }

    private var profileLabel: some View {
        Group {
            if let img = appState.userProfileImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.primary)
                    .opacity(0.85)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
        .contentShape(Circle())
        .accessibilityLabel(appState.username.isEmpty ? "Account" : appState.username)
    }

    // Physically resize the UIImage so the native Menu renderer doesn't use the original massive asset size
    private var resizedDiscordIcon: Image {
        let side: CGFloat = isRunningOnMac ? 14 : 18
        let targetSize = CGSize(width: side, height: side)
        
        guard let uiImage = UIImage(named: "Discord Logo") else {
            return Image(systemName: "bubble.left.and.bubble.right.fill") // Fallback if asset is missing
        }
        
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedUIImage = renderer.image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        
        // .alwaysOriginal prevents the system from tinting the colorful Discord logo to a solid monochrome color
        return Image(uiImage: resizedUIImage.withRenderingMode(.alwaysOriginal))
    }

    private func openDiscord() {
        if let url = URL(string: "https://discord.gg/xGdey3dxQN") {
            UIApplication.shared.open(url)
        }
    }

    private func ensureProfileLoadedIfNeeded() {
        if appState.isLoggedIn && appState.userProfileImage == nil {
            Task { await appState.refreshUserProfileInfoAndImage() }
        }
    }
}
