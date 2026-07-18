//
//  MediaSourceDto.swift
//  LiveFin
//
//  Created by KPGamingz on 7/14/26

import Foundation

// MARK: - Core DTOs

struct MediaSourceDto: Codable {
    let id: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

struct BaseItemDto: Identifiable, Codable {
    let id: String?
    let name: String?
    let startDate: Date?
    let endDate: Date?
    let overview: String?
    let channelId: String?
    let mediaSources: [MediaSourceDto]?
    let officialRating: String?
    let episodeTitle: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let isRepeat: Bool?
    let isPremiere: Bool?
    let isNew: Bool?
    let isMovie: Bool?
    let seriesName: String?
    let genres: [String]?
    
    let timerId: String?
    let seriesTimerId: String?
    
    let seriesId: String?
    let isSeries: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case overview = "Overview"
        case channelId = "ChannelId"
        case mediaSources = "MediaSources"
        case officialRating = "OfficialRating"
        case episodeTitle = "EpisodeTitle"
        case subtitle = "Subtitle"
        case seriesName = "SeriesName"
        case genres = "Genres"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case isRepeat = "IsRepeat"
        case isPremiere = "IsPremiere"
        case isNew = "IsNew"
        case isMovie = "IsMovie"
        case programId = "ProgramId"
        case timerId = "TimerId"
        case seriesTimerId = "SeriesTimerId"
        case seriesId = "SeriesId"
        case isSeries = "IsSeries"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let idValue = try? container.decode(String.self, forKey: .id) {
            id = idValue
        } else {
            id = try? container.decode(String.self, forKey: .programId)
        }
        name = try? container.decode(String.self, forKey: .name)
        startDate = try? container.decode(Date.self, forKey: .startDate)
        endDate = try? container.decode(Date.self, forKey: .endDate)
        overview = try? container.decode(String.self, forKey: .overview)
        channelId = try? container.decode(String.self, forKey: .channelId)
        mediaSources = try? container.decode([MediaSourceDto].self, forKey: .mediaSources)
        officialRating = try? container.decode(String.self, forKey: .officialRating)
        
        if let ep = try? container.decode(String.self, forKey: .episodeTitle), !ep.isEmpty {
            episodeTitle = ep
        } else if let sub = try? container.decode(String.self, forKey: .subtitle), !sub.isEmpty {
            episodeTitle = sub
        } else {
            episodeTitle = nil
        }
        seriesName = try? container.decode(String.self, forKey: .seriesName)
        if let gs = try? container.decode([String].self, forKey: .genres) {
            genres = gs
        } else if let any = try? container.decode([AnyCodable].self, forKey: .genres) {
            genres = any.compactMap { $0.value as? String }
        } else {
            genres = nil
        }
        parentIndexNumber = try? container.decode(Int.self, forKey: .parentIndexNumber)
        indexNumber = try? container.decode(Int.self, forKey: .indexNumber)
        isRepeat = try? container.decode(Bool.self, forKey: .isRepeat)
        isPremiere = try? container.decode(Bool.self, forKey: .isPremiere)
        isNew = try? container.decode(Bool.self, forKey: .isNew)
        isMovie = try? container.decode(Bool.self, forKey: .isMovie)
        
        timerId = try? container.decode(String.self, forKey: .timerId)
        seriesTimerId = try? container.decode(String.self, forKey: .seriesTimerId)
        seriesId = try? container.decode(String.self, forKey: .seriesId)
        isSeries = try? container.decode(Bool.self, forKey: .isSeries)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(overview, forKey: .overview)
        try container.encodeIfPresent(channelId, forKey: .channelId)
        try container.encodeIfPresent(mediaSources, forKey: .mediaSources)
        try container.encodeIfPresent(officialRating, forKey: .officialRating)
        try container.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try container.encodeIfPresent(seriesName, forKey: .seriesName)
        try container.encodeIfPresent(genres, forKey: .genres)
        try container.encodeIfPresent(parentIndexNumber, forKey: .parentIndexNumber)
        try container.encodeIfPresent(indexNumber, forKey: .indexNumber)
        try container.encodeIfPresent(isRepeat, forKey: .isRepeat)
        try container.encodeIfPresent(isPremiere, forKey: .isPremiere)
        try container.encodeIfPresent(isNew, forKey: .isNew)
        try container.encodeIfPresent(isMovie, forKey: .isMovie)
        try container.encodeIfPresent(timerId, forKey: .timerId)
        try container.encodeIfPresent(seriesTimerId, forKey: .seriesTimerId)
        try container.encodeIfPresent(seriesId, forKey: .seriesId)
        try container.encodeIfPresent(isSeries, forKey: .isSeries)
    }
}

struct UserDataDto: Codable {
    let isFavorite: Bool?
    enum CodingKeys: String, CodingKey { case isFavorite = "IsFavorite" }
    
    init(isFavorite: Bool?) {
        self.isFavorite = isFavorite
    }
}

struct LiveTvChannelDto: Codable, Identifiable {
    let id: String
    let name: String?
    let number: String?
    let startDate: Date?
    let endDate: Date?
    let baseURL: String
    var currentProgram: BaseItemDto?
    var userData: UserDataDto?

    var streamUrl: String { "/LiveTv/LiveStream?channelId=\(id)" }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case number = "Number"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case userData = "UserData"
    }

    init(id: String, name: String?, number: String?, startDate: Date?, endDate: Date?, baseURL: String, userData: UserDataDto? = nil) {
        self.id = id
        self.name = name
        self.number = number
        self.startDate = startDate
        self.endDate = endDate
        self.baseURL = baseURL
        self.currentProgram = nil
        self.userData = userData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.number = try container.decodeIfPresent(String.self, forKey: .number)
        self.startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        self.endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        self.userData = try container.decodeIfPresent(UserDataDto.self, forKey: .userData)
        self.baseURL = "YOUR_SERVER_BASE_URL"
        self.currentProgram = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(userData, forKey: .userData)
    }
}

// MARK: - Responses

struct ProgramsResponse: Codable {
    let items: [BaseItemDto]?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct ChannelsResponse: Codable {
    let items: [LiveTvChannelDto]?
    
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

// MARK: - Helpers

struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { value = s; return }
        if let i = try? container.decode(Int.self) { value = i; return }
        if let d = try? container.decode(Double.self) { value = d; return }
        if let b = try? container.decode(Bool.self) { value = b; return }
        if let arr = try? container.decode([AnyCodable].self) { value = arr.map { $0.value }; return }
        if let dict = try? container.decode([String: AnyCodable].self) { var out: [String: Any] = [:]; for (k,v) in dict { out[k] = v.value }; value = out; return }
        value = ""
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let s as String: try container.encode(s)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let b as Bool: try container.encode(b)
        case let arr as [Any]: try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
        default: try container.encode(String(describing: value))
        }
    }
}
