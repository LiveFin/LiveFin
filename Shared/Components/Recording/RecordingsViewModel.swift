//
//  RecordingsViewModel.swift
//  LiveFin
//
//  Created by KPGamingz on 7/6/26.
//

import Foundation
import SwiftUI

@MainActor
final class RecordingsViewModel: ObservableObject {
    @Published var scheduledTimers: [JFTimer] = []
    @Published var scheduledSeriesTimers: [JFSeriesTimer] = []
    @Published var pastRecordings: [JFItemDto] = [] // Mapped directly for MediaItemDetailView
    @Published var isInitialLoad = true
    @Published var hasDvrAccess = true
    
    private let appState: AppState
    private var activeFetchTask: Task<Void, Never>?
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    /// Public entry point. Cancels any in-flight fetch before starting a new one so
    /// a pull-to-refresh (or a rapid re-appear) can't race an older fetch and have
    /// its stale result overwrite newer/optimistic state (e.g. a just-cancelled timer
    /// reappearing because an older in-flight request finished after the cancel).
    func fetchAll() async {
        activeFetchTask?.cancel()
        let task = Task { await self.performFetchAll() }
        activeFetchTask = task
        await task.value
    }

    private func performFetchAll() async {
        // Fire all three requests independently so each one publishes to the UI
        // the moment IT finishes, instead of the whole view waiting on whichever
        // endpoint happens to be slowest (previously gated behind a single
        // `try await (timers, seriesTimers, recordings)` tuple, which blocks
        // ALL three arrays from updating until the slowest call returns).
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadTimers() }
            group.addTask { await self.loadSeriesTimers() }
            group.addTask { await self.loadRecordings() }
        }
        isInitialLoad = false
    }

    private func loadTimers() async {
        do {
            let t = try await fetchTimers()
            self.scheduledTimers = t.sorted { ($0.parsedStartDate ?? .distantFuture) < ($1.parsedStartDate ?? .distantFuture) }
        } catch is CancellationError {
            // View disappeared / rapid refresh — leave existing state alone.
        } catch {
            print("Fetch timers failed: \(error)")
        }
    }

    private func loadSeriesTimers() async {
        do {
            self.scheduledSeriesTimers = try await fetchSeriesTimers()
        } catch is CancellationError {
        } catch {
            print("Fetch series timers failed: \(error)")
        }
    }

    private func loadRecordings() async {
        do {
            self.pastRecordings = try await fetchRecordings()
        } catch is CancellationError {
        } catch {
            print("Fetch recordings failed: \(error)")
        }
    }
    
    private func fetchTimers() async throws -> [JFTimer] {
        let cleanBaseURL = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: cleanBaseURL)?.appendingPathComponent("LiveTv/Timers") else { return [] }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !appState.accessToken.isEmpty { request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    Task { @MainActor in self.hasDvrAccess = false }
                    return []
                }
            }
            
            struct JFQueryResult<T: Codable>: Codable { let Items: [T] }
            let parsed = try JSONDecoder().decode(JFQueryResult<JFTimer>.self, from: data)
            return parsed.Items
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            print("Failed to fetch timers: \(error)")
            return []
        }
    }
    
    private func fetchSeriesTimers() async throws -> [JFSeriesTimer] {
        let cleanBaseURL = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: cleanBaseURL)?.appendingPathComponent("LiveTv/SeriesTimers") else { return [] }
        
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Request ImageTags along with other fields
        comps?.queryItems = [URLQueryItem(name: "Fields", value: "SeriesId,ProgramId,Overview,ImageTags")]
        
        guard let requestUrl = comps?.url else { return [] }
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "GET"
        if !appState.accessToken.isEmpty { request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    Task { @MainActor in self.hasDvrAccess = false }
                    return []
                }
            }
            
            struct JFQueryResult<T: Codable>: Codable { let Items: [T] }
            let parsed = try JSONDecoder().decode(JFQueryResult<JFSeriesTimer>.self, from: data)
            return parsed.Items
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            print("Failed to fetch series timers: \(error)")
            return []
        }
    }
    
    private func fetchRecordings() async throws -> [JFItemDto] {
        let cleanBaseURL = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: cleanBaseURL)?.appendingPathComponent("LiveTv/Recordings") else { return [] }
        
        // Request SeriesId so the DestinationWrapper correctly routes to the Show page!
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "Fields", value: "SeriesId,Overview,ImageTags")]
        guard let requestUrl = comps?.url else { return [] }
        
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "GET"
        if !appState.accessToken.isEmpty { request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    Task { @MainActor in self.hasDvrAccess = false }
                    return []
                }
            }
            
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let parsed = try JSONDecoder().decode(ItemsResponse.self, from: data)
            return parsed.Items
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            print("Failed to fetch recordings: \(error)")
            return []
        }
    }
    
    func cancelTimer(id: String) async {
        let cleanBaseURL = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: cleanBaseURL)?.appendingPathComponent("LiveTv/Timers/\(id)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if !appState.accessToken.isEmpty { request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                // Instantly remove it from the UI upon success
                self.scheduledTimers.removeAll { $0.Id == id }
                Task { await JellyfinTimerCache.shared.clearCache() }
            }
        } catch {
            print("Failed to cancel timer: \(error)")
        }
    }
    
    func cancelSeriesTimer(id: String) async {
        let cleanBaseURL = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: cleanBaseURL)?.appendingPathComponent("LiveTv/SeriesTimers/\(id)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if !appState.accessToken.isEmpty { request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                self.scheduledSeriesTimers.removeAll { $0.Id == id }
                Task { await JellyfinTimerCache.shared.clearCache() }
            }
        } catch {
            print("Failed to cancel series timer: \(error)")
        }
    }
}
