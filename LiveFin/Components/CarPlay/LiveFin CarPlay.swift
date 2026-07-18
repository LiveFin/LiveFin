//
//  LiveFin CarPlay.swift
//  LiveFin
//
//  Created by KPGamingz on 7/15/26.
//

import Foundation
import CarPlay
import AVFoundation
import MediaPlayer
import UIKit

class LiveFinCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    
    var interfaceController: CPInterfaceController?
    var player: AVPlayer?
    
    // Metadata refresh state
    private var metadataTask: Task<Void, Never>?
    private var currentPlayingChannel: LiveTvChannelDto?
    private var currentPlayingProgram: BaseItemDto?
    
    // Create a local AppState to restore session from Keychain
    let appState = AppState()
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        
        // 1. Configure Audio Session for CarPlay (Crucial for audio/video routing)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("CarPlay: Failed to set audio session category - \(error)")
        }
        
        // 2. Add the custom "Show Video on iPhone" Button
        let showOnIphoneButton = CPNowPlayingImageButton(image: UIImage(systemName: "iphone.badge.play") ?? UIImage()) { [weak self] _ in
            guard let self = self else { return }
            
            // Pause audio in CarPlay before transitioning to phone
            self.player?.pause()
            
            // Notify the iPhone to open DragonetPlayerView
            // We pass the channel and program data in the notification
            let userInfo: [String: Any] = [
                "channel": self.currentPlayingChannel as Any,
                "program": self.currentPlayingProgram as Any
            ]
            NotificationCenter.default.post(name: NSNotification.Name("LiveFinShowVideoOnIphone"), object: nil, userInfo: userInfo)
            
            // Pop the Now Playing template to return to the channel list in CarPlay
            self.interfaceController?.popTemplate(animated: true)
        }
        
        // 3. Inject the custom handoff button into the shared Now Playing template
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([showOnIphoneButton])
        
        // Setup Remote Commands so CarPlay/Now Playing can control the app
        setupRemoteCommands()
        
        let liveTvTemplate = createLiveTvTemplate()
        let tabBarTemplate = CPTabBarTemplate(templates: [liveTvTemplate])
        
        interfaceController.setRootTemplate(tabBarTemplate, animated: true)
        
        Task {
            await appState.restoreLogin()
            await loadChannels(into: liveTvTemplate)
        }
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        self.player?.pause()
        self.player = nil
        self.metadataTask?.cancel()
        self.metadataTask = nil
        print("LiveFin disconnected from CarPlay.")
    }
    
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Clear previous targets to avoid duplicate triggers
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        
        commandCenter.playCommand.addTarget { [weak self] event in
            self?.player?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] event in
            self?.player?.pause()
            return .success
        }
    }
    
    private func createLiveTvTemplate() -> CPListTemplate {
        let loadingItem = CPListItem(text: "Loading Channels...", detailText: nil)
        let section = CPListSection(items: [loadingItem], header: "Live TV", sectionIndexTitle: nil)
        
        let listTemplate = CPListTemplate(title: "Live TV", sections: [section])
        listTemplate.tabSystemItem = .mostRecent
        
        // Navigation bar button to manually open the system Now Playing template
        let nowPlayingButton = CPBarButton(image: UIImage(systemName: "play.tv.fill")!) { [weak self] _ in
            guard let interfaceController = self?.interfaceController else { return }
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, error in
                if let error = error {
                    print("CarPlay: Failed to push Now Playing template - \(error)")
                }
            }
        }
        listTemplate.trailingNavigationBarButtons = [nowPlayingButton]
        
        return listTemplate
    }
    
    // Creates a custom decoder to handle Jellyfin's specific ISO8601 date strings
    private func createJellyfinDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            let s = try c.decode(String.self)
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let dt = f1.date(from: s) { return dt }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            if let dt2 = f2.date(from: s) { return dt2 }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(s)")
        }
        return decoder
    }
    
    private func loadChannels(into template: CPListTemplate) async {
        let serverURL = appState.serverURL
        let userId = appState.userID
        let accessToken = appState.accessToken
        
        guard !serverURL.isEmpty, !accessToken.isEmpty else {
            let emptyItem = CPListItem(text: "Not Logged In", detailText: "Please log in on your iPhone first.")
            template.updateSections([CPListSection(items: [emptyItem])])
            return
        }
        
        let cleanBaseURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        guard let channelsUrl = URL(string: "\(cleanBaseURL)/LiveTv/Channels?userId=\(userId)&EnableTotalRecordCount=false") else { return }
        
        var channelsReq = URLRequest(url: channelsUrl)
        channelsReq.setValue(appState.getAuthorizationHeader(includeToken: true), forHTTPHeaderField: "Authorization")
        
        let now = Date()
        let end = now.addingTimeInterval(3600 * 2) // Look ahead 2 hours
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let programsUrl = URL(string: "\(cleanBaseURL)/LiveTv/Programs?userId=\(userId)&startDate=\(iso.string(from: now))&endDate=\(iso.string(from: end))&EnableTotalRecordCount=false") else { return }
        
        var programsReq = URLRequest(url: programsUrl)
        programsReq.setValue(appState.getAuthorizationHeader(includeToken: true), forHTTPHeaderField: "Authorization")
        
        do {
            async let channelsTask = URLSession.shared.data(for: channelsReq)
            async let programsTask = URLSession.shared.data(for: programsReq)
            
            let (channelsData, _) = try await channelsTask
            let (programsData, _) = try await programsTask
            
            let decoder = createJellyfinDecoder()
            let channelsResponse = try decoder.decode(ChannelsResponse.self, from: channelsData)
            let programsResponse = try decoder.decode(ProgramsResponse.self, from: programsData)
            
            guard let channels = channelsResponse.items, !channels.isEmpty else {
                let emptyItem = CPListItem(text: "No Channels Found", detailText: "Check your server tuners.")
                template.updateSections([CPListSection(items: [emptyItem])])
                return
            }
            
            // Map currently airing programs
            var currentProgramsMap: [String: BaseItemDto] = [:]
            if let programs = programsResponse.items {
                for prog in programs {
                    guard let cid = prog.channelId else { continue }
                    if let start = prog.startDate, let end = prog.endDate {
                        if start <= now && now <= end {
                            currentProgramsMap[cid] = prog
                        }
                    }
                }
            }
            
            // Sort channels numerically
            let sortedChannels = channels.sorted { c1, c2 in
                let num1 = Double(c1.number ?? "") ?? 99999.0
                let num2 = Double(c2.number ?? "") ?? 99999.0
                return num1 < num2
            }
            
            let listItems = sortedChannels.map { channel -> CPListItem in
                let channelText = [channel.number, channel.name].compactMap { $0 }.joined(separator: " - ")
                let activeProgram = currentProgramsMap[channel.id]
                
                // Format subtitle / episode info
                var detailText = activeProgram?.name ?? "No Program Info"
                if let subtitle = activeProgram?.episodeTitle ?? activeProgram?.seriesName, subtitle != activeProgram?.name {
                    detailText += " • \(subtitle)"
                }
                
                let item = CPListItem(text: channelText, detailText: detailText)
                item.setImage(UIImage(systemName: "tv")) // Base fallback
                
                // Asynchronously load the channel or program image
                Task {
                    let imageId = activeProgram?.id ?? channel.id
                    let urlString = "\(cleanBaseURL)/Items/\(imageId)/Images/Primary?maxWidth=200&api_key=\(accessToken)"
                    if let url = URL(string: urlString),
                       let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url)),
                       let image = UIImage(data: data) {
                        await MainActor.run { item.setImage(image) }
                    }
                }
                
                item.handler = { [weak self] item, completion in
                    self?.handleChannelSelection(channel: channel, program: activeProgram, completion: completion)
                }
                return item
            }
            
            let section = CPListSection(items: listItems, header: "All Channels", sectionIndexTitle: nil)
            template.updateSections([section])
            
        } catch {
            print("CarPlay: Failed to fetch channels/programs - \(error)")
            let errorItem = CPListItem(text: "Failed to load channels", detailText: error.localizedDescription)
            template.updateSections([CPListSection(items: [errorItem])])
        }
    }
    
    private func handleChannelSelection(channel: LiveTvChannelDto, program: BaseItemDto?, completion: @escaping () -> Void) {
        let tuningAlert = CPAlertTemplate(titleVariants: ["Tuning to \(channel.name ?? "Channel")..."], actions: [])
        self.interfaceController?.presentTemplate(tuningAlert, animated: true)
        
        Task {
            let resolvedStream = await JFOpenLiveStreamService.resolveStreamURLWithSession(
                channelId: channel.id,
                userId: appState.userID,
                serverURL: appState.serverURL,
                accessToken: appState.accessToken,
                deviceId: appState.deviceId,
                debug: true
            )
            
            await MainActor.run {
                self.interfaceController?.dismissTemplate(animated: true)
            }
            
            guard let finalUrlStr = resolvedStream.url, let finalUrl = URL(string: finalUrlStr) else {
                await MainActor.run {
                    let errorAlert = CPAlertTemplate(titleVariants: ["Playback Failed"], actions: [])
                    self.interfaceController?.presentTemplate(errorAlert, animated: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self.interfaceController?.dismissTemplate(animated: true)
                    }
                }
                completion()
                return
            }
            
            await MainActor.run {
                // 1. Initialize AVPlayer
                let playerItem = AVPlayerItem(url: finalUrl)
                self.player = AVPlayer(playerItem: playerItem)
                self.player?.play()
                
                self.currentPlayingChannel = channel
                self.currentPlayingProgram = program
                
                // 2. Automatically push the Now Playing template upon successful selection
                self.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, error in
                    if let error = error {
                        print("CarPlay: Failed to auto-push Now Playing - \(error)")
                    }
                }
                
                // 3. Start metadata refresh timer
                self.startMetadataTimer()
            }
            
            // 4. Update metadata and fetch high-res artwork asynchronously
            Task {
                await self.updateNowPlayingInfo(channel: channel, program: program)
            }
            
            completion()
        }
    }
    
    // MARK: - Metadata Refresh Loop
    
    private func startMetadataTimer() {
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            while !Task.isCancelled {
                // Check every 60 seconds
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshMetadata()
            }
        }
    }
    
    private func refreshMetadata() async {
        guard let channel = currentPlayingChannel else { return }
        let serverURL = appState.serverURL
        let userId = appState.userID
        let cleanBaseURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        
        let now = Date()
        let end = now.addingTimeInterval(3600) // Look ahead 1 hour
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        let channelId = channel.id ?? ""
        guard let programsUrl = URL(string: "\(cleanBaseURL)/LiveTv/Programs?userId=\(userId)&channelIds=\(channelId)&startDate=\(iso.string(from: now))&endDate=\(iso.string(from: end))&EnableTotalRecordCount=false") else { return }
        
        var programsReq = URLRequest(url: programsUrl)
        programsReq.setValue(appState.getAuthorizationHeader(includeToken: true), forHTTPHeaderField: "Authorization")
        
        do {
            let (programsData, _) = try await URLSession.shared.data(for: programsReq)
            let decoder = createJellyfinDecoder()
            let programsResponse = try decoder.decode(ProgramsResponse.self, from: programsData)
            
            var activeProgram: BaseItemDto? = nil
            if let programs = programsResponse.items {
                for prog in programs {
                    if let start = prog.startDate, let end = prog.endDate {
                        if start <= now && now <= end {
                            activeProgram = prog
                            break
                        }
                    }
                }
            }
            
            // If the program changed, update
            if activeProgram?.id != self.currentPlayingProgram?.id {
                self.currentPlayingProgram = activeProgram
                await self.updateNowPlayingInfo(channel: channel, program: activeProgram)
            }
        } catch {
            print("CarPlay: Failed to refresh program metadata - \(error)")
        }
    }
    
    private func updateNowPlayingInfo(channel: LiveTvChannelDto, program: BaseItemDto?) async {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = program?.name ?? channel.name
        nowPlayingInfo[MPMediaItemPropertyArtist] = channel.name
        
        // Map the subtitle or episode name to AlbumTitle
        if let subtitle = program?.episodeTitle ?? program?.seriesName, subtitle != program?.name {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = subtitle
        } else if let overview = program?.overview {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = overview
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        
        // Push text updates immediately so UI feels responsive
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        // Fetch new artwork
        let imageId = program?.id ?? channel.id
        let cleanBaseURL = self.appState.serverURL.hasSuffix("/") ? String(self.appState.serverURL.dropLast()) : self.appState.serverURL
        
        let urlString = "\(cleanBaseURL)/Items/\(imageId)/Images/Primary?maxWidth=600&api_key=\(self.appState.accessToken)"
        
        if let url = URL(string: urlString),
           let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url)),
           let image = UIImage(data: data) {
            await MainActor.run {
                // Re-fetch current info in case it changed while downloading
                var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
                let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: { _ in return image })
                updatedInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
            }
        }
    }
}
