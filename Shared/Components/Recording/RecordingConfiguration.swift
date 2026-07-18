//
//  RecordingConfiguration.swift
//  LiveFin
//
//  Created by KPGamingz on 7/6/26.
//


import Foundation

// MARK: - App Models

struct RecordingConfiguration: Equatable {
    var prePaddingSeconds: Int = 0
    var postPaddingSeconds: Int = 0
    var isSeriesTimer: Bool = false
    var recordAnyTime: Bool = false
    var recordAnyChannel: Bool = false
    var recordNewOnly: Bool = false
}

struct NotificationConfiguration: Equatable {
    var notificationBufferSeconds: Int = 300 // Default 5 minutes before
    var notifySeries: Bool = false
    var notifyNewEpisodesOnly: Bool = false
    var repeatNotification: Bool = false
    var notifyOnFinish: Bool = false
}

// MARK: - API Response Models

// Decodes the default padding settings from the server
struct JFDefaultTimerResponse: Decodable {
    let PrePaddingSeconds: Int?
    let PostPaddingSeconds: Int?
}

// Decodes the ID returned after successfully scheduling a recording
struct JFTimerResponse: Decodable {
    let Id: String
}

// Represents an active timer returned by the server for scheduled items
struct JFTimer: Identifiable, Codable {
    let Id: String
    let ProgramId: String?
    let ChannelId: String?
    let Name: String?
    let Overview: String?
    let StartDate: String?
    let EndDate: String?
    let ChannelName: String?
    let Status: String?
    let PrePaddingSeconds: Int?
    let PostPaddingSeconds: Int?
    let SeriesTimerId: String?
    
    struct JFProgramInfo: Codable {
        let Id: String?
        let ImageTags: [String: String]?
    }
    let ProgramInfo: JFProgramInfo?
    
    // Conforms to Identifiable using Jellyfin's uppercase Id
    var id: String { Id }
    
    var primaryImageTag: String? {
        ProgramInfo?.ImageTags?["Primary"]
    }
    
    var parsedStartDate: Date? {
        guard let s = StartDate else { return nil }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
    
    var parsedEndDate: Date? {
        guard let s = EndDate else { return nil }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
}

// Represents an active series timer returned by the server
struct JFSeriesTimer: Identifiable, Codable {
    let Id: String
    let ChannelId: String?
    let Name: String?
    let RecordAnyTime: Bool?
    let RecordNewOnly: Bool?
    let SeriesId: String? // Note: not actually part of Jellyfin's SeriesTimerInfoDto; the server never populates this.
    let ProgramId: String?
    let ImageTags: [String: String]?
    
    // These come straight off SeriesTimerInfoDto and are the reliable source for series
    // artwork -- ProgramId only points at the one-off EPG entry that spawned the rule,
    // which is frequently gone by the time the timer is displayed.
    let ParentPrimaryImageItemId: String?
    let ParentPrimaryImageTag: String?
    let ParentThumbItemId: String?
    let ParentThumbImageTag: String?
    
    // Server wraps many program details in an inner ProgramInfo object
    struct JFProgramInfo: Codable {
        let Id: String?
        let ImageTags: [String: String]?
    }
    let ProgramInfo: JFProgramInfo?
    
    var fallbackImageTag: String?
    var fallbackProgramId: String?
    
    // Coalesce fallback checks for the Primary image tag across known locations
    var primaryImageTag: String? {
        ParentPrimaryImageTag ?? ImageTags?["Primary"] ?? ProgramInfo?.ImageTags?["Primary"] ?? fallbackImageTag
    }
    
    var effectiveProgramId: String {
        ParentPrimaryImageItemId ?? ProgramInfo?.Id ?? ProgramId ?? SeriesId ?? fallbackProgramId ?? Id
    }
    
    var id: String { Id }
}
