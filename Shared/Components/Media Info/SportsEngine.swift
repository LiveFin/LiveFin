//
//  SportsStatsEngine.swift
//  LiveFin
//
//  Created by KPGamingz on 9/13/26.
//

import Foundation

// MARK: - Supported Leagues & Sports

public enum SupportedLeague: String, CaseIterable, Sendable {
case ncaaf = "football/college-football"
case nfl = "football/nfl"
case nba = "basketball/nba"
case ncaam = "basketball/mens-college-basketball"
case mlb = "baseball/mlb"
case nhl = "hockey/nhl"
case mls = "soccer/usa.1"
case epl = "soccer/eng.1"

public var displayName: String {
    switch self {
    case .ncaaf: return "NCAA Football"
    case .nfl: return "NFL"
    case .nba: return "NBA"
    case .ncaam: return "NCAA Basketball"
    case .mlb: return "MLB"
    case .nhl: return "NHL"
    case .mls: return "MLS"
    case .epl: return "Premier League"
    }
}


}

// MARK: - Data Models

public struct MatchQuery: Sendable, Hashable {
public let league: SupportedLeague
public let homeTeamRaw: String
public let awayTeamRaw: String
public let broadcastDate: Date
public let isPregame: Bool
public let isPostgame: Bool

public init(
    league: SupportedLeague,
    homeTeamRaw: String,
    awayTeamRaw: String,
    broadcastDate: Date,
    isPregame: Bool = false,
    isPostgame: Bool = false
) {
    self.league = league
    self.homeTeamRaw = homeTeamRaw
    self.awayTeamRaw = awayTeamRaw
    self.broadcastDate = broadcastDate
    self.isPregame = isPregame
    self.isPostgame = isPostgame
}


}

public struct LiveGameScore: Sendable, Identifiable, Equatable {
public let id: String
public let league: SupportedLeague

// Home Team
public let homeTeamName: String
public let homeTeamAbbr: String
public let homeScore: Int
public let homeRank: Int?
public let homeRecord: String?
public let homeLogoURL: URL?
public let homeLineScores: [Int]

// Away Team
public let awayTeamName: String
public let awayTeamAbbr: String
public let awayScore: Int
public let awayRank: Int?
public let awayRecord: String?
public let awayLogoURL: URL?
public let awayLineScores: [Int]

// Game Status & Meta
public let statusDisplay: String
public let isLive: Bool
public let isFinal: Bool
public let isPreGame: Bool
public let startTimeDisplay: String?
public let venueName: String?
public let broadcastNetwork: String?
public let oddsSummary: String?
public let overUnder: String?
public let lastUpdated: Date

public init(
    id: String,
    league: SupportedLeague,
    homeTeamName: String,
    homeTeamAbbr: String,
    homeScore: Int,
    homeRank: Int? = nil,
    homeRecord: String? = nil,
    homeLogoURL: URL? = nil,
    homeLineScores: [Int] = [],
    awayTeamName: String,
    awayTeamAbbr: String,
    awayScore: Int,
    awayRank: Int? = nil,
    awayRecord: String? = nil,
    awayLogoURL: URL? = nil,
    awayLineScores: [Int] = [],
    statusDisplay: String,
    isLive: Bool,
    isFinal: Bool,
    isPreGame: Bool = false,
    startTimeDisplay: String? = nil,
    venueName: String? = nil,
    broadcastNetwork: String? = nil,
    oddsSummary: String? = nil,
    overUnder: String? = nil,
    lastUpdated: Date = Date()
) {
    self.id = id
    self.league = league
    self.homeTeamName = homeTeamName
    self.homeTeamAbbr = homeTeamAbbr
    self.homeScore = homeScore
    self.homeRank = homeRank
    self.homeRecord = homeRecord
    self.homeLogoURL = homeLogoURL
    self.homeLineScores = homeLineScores
    self.awayTeamName = awayTeamName
    self.awayTeamAbbr = awayTeamAbbr
    self.awayScore = awayScore
    self.awayRank = awayRank
    self.awayRecord = awayRecord
    self.awayLogoURL = awayLogoURL
    self.awayLineScores = awayLineScores
    self.statusDisplay = statusDisplay
    self.isLive = isLive
    self.isFinal = isFinal
    self.isPreGame = isPreGame
    self.startTimeDisplay = startTimeDisplay
    self.venueName = venueName
    self.broadcastNetwork = broadcastNetwork
    self.oddsSummary = oddsSummary
    self.overUnder = overUnder
    self.lastUpdated = lastUpdated
}


}

// MARK: - Match Parser Engine

public final class SportsMatchEngine: Sendable {
public static let shared = SportsMatchEngine()

private init() {}

private static let teamSeparators = [
    #"\s+vs\.?\s+"#,
    #"\s+v\s+"#,
    #"\s+at\s+"#,
    #"\s+@\s+"#,
    #"\s+-\s+"#
]

/// Studio talk shows and non-live game broadcasts that must NEVER trigger stats
private static let nonGameShowKeywords: [String] = [
    "sportscenter", "sports center", "first take", "pardon the interruption",
    "pti", "around the horn", "get up", "nfl live", "nfl total access",
    "college gameday", "game day", "pat mcafee", "inside the nba",
    "undisputed", "first things first", "the herd", "speak",
    "good morning football", "gmfb", "baseball tonight", "nfl countdown",
    "monday night countdown", "sunday nfl countdown", "nba countdown",
    "outside the lines", "fox sports live", "fox nfl sunday", "the daily wagers",
    "sports night", "sports report", "highlights", "press conference",
    "special report", "documentary", "30 for 30", "e:60", "recap"
]

/// Common words that should not trigger false positive token matches
private static let sportsStopWords: Set<String> = [
    "state", "st", "tech", "city", "new", "san", "los", "north", "south",
    "east", "west", "green", "bay", "the", "and", "of", "fc", "sc",
    "university", "college", "club", "united", "city", "real", "national",
    "pregame", "postgame", "kickoff", "halftime"
]

/// Determines if a title/subtitle indicates a non-game studio program or talk show
public func isTalkOrStudioShow(title: String?, subtitle: String?) -> Bool {
    let combined = "\(title ?? "") \(subtitle ?? "")".lowercased()
    for show in Self.nonGameShowKeywords {
        if combined.contains(show) {
            // If it contains "pregame" or "postgame" WITH an actual matchup separator, allow it to be evaluated as a preview/postgame
            let hasMatchupSeparator = Self.teamSeparators.contains { pattern in
                (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
                    .firstMatch(in: combined, range: NSRange(combined.startIndex..<combined.endIndex, in: combined)) != nil
            }
            if hasMatchupSeparator && (combined.contains("pregame") || combined.contains("postgame")) {
                return false
            }
            return true
        }
    }
    return false
}

/// Quick heuristic to determine if content could belong to live sports matches
public func isSportsContent(
    title: String?,
    subtitle: String?,
    channelName: String? = nil,
    genres: [String]? = nil
) -> Bool {
    // 1. Instantly reject known talk shows and studio debate broadcasts
    if isTalkOrStudioShow(title: title, subtitle: subtitle) {
        return false
    }

    if let g = genres, !g.isEmpty {
        let sportsGenres = ["sport", "sports", "football", "basketball", "baseball", "hockey", "soccer"]
        if g.contains(where: { genre in sportsGenres.contains(where: { genre.localizedCaseInsensitiveContains($0) }) }) {
            return true
        }
    }

    let combined = "\(title ?? "") \(subtitle ?? "") \(channelName ?? "")".lowercased()
    if detectLeague(from: combined) != nil {
        return true
    }

    return false
}

/// Parses EPG program titles, subtitles, channel names, and broadcast dates into a structured `MatchQuery`.
public func parseQuery(
    title: String?,
    subtitle: String?,
    channelName: String? = nil,
    genres: [String]? = nil,
    startDate: Date?
) -> MatchQuery? {
    let rawTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rawSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rawChannel = channelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let allGenres = (genres ?? []).joined(separator: " ").lowercased()

    guard !rawTitle.isEmpty || !rawSubtitle.isEmpty else { return nil }

    // 1. Discard talk shows and studio programs unless accompanied by a specific game
    if isTalkOrStudioShow(title: rawTitle, subtitle: rawSubtitle) {
        return nil
    }

    // 2. Detect League
    let combinedHeader = "\(rawTitle) \(rawSubtitle) \(rawChannel) \(allGenres)"
    guard let league = detectLeague(from: combinedHeader) else {
        return nil
    }

    let isPregame = combinedHeader.lowercased().contains("pregame") || combinedHeader.lowercased().contains("preview")
    let isPostgame = combinedHeader.lowercased().contains("postgame") || combinedHeader.lowercased().contains("post-game")

    // 3. Extract Team Sides from subtitle or title
    var sides: (String, String, Bool)?

    if !rawSubtitle.isEmpty && rawSubtitle.count < 90 {
        let sanitizedSub = sanitizeNoise(rawSubtitle)
        if let extracted = extractTeams(from: sanitizedSub) {
            sides = extracted
        }
    }

    if sides == nil && !rawTitle.isEmpty {
        let sanitizedTitle = sanitizeNoise(rawTitle)
        if let extracted = extractTeams(from: sanitizedTitle) {
            sides = extracted
        }
    }

    guard let (sideA, sideB, isAtFormat) = sides else {
        return nil
    }

    let homeCleaned = cleanTeamName(isAtFormat ? sideB : sideA)
    let awayCleaned = cleanTeamName(isAtFormat ? sideA : sideB)

    guard !homeCleaned.isEmpty, !awayCleaned.isEmpty else {
        return nil
    }

    return MatchQuery(
        league: league,
        homeTeamRaw: homeCleaned,
        awayTeamRaw: awayCleaned,
        broadcastDate: startDate ?? Date(),
        isPregame: isPregame,
        isPostgame: isPostgame
    )
}

public func detectLeague(from string: String) -> SupportedLeague? {
    let t = string.lowercased()
    
    // College Football
    if t.contains("college football") ||
       t.contains("ncaa football") ||
       t.contains("cfb") ||
       t.contains("sec on cbs") ||
       t.contains("big ten football") ||
       t.contains("acc football") ||
       t.contains("big 12 football") ||
       t.contains("college football playoff") ||
       t.contains("cfp") ||
       t.contains("sec network") ||
       t.contains("acc network") ||
       t.contains("big ten network") ||
       t.contains("btn") ||
       (t.contains("bowl") && (t.contains("football") || t.contains("ncaa") || t.contains("college"))) {
        return .ncaaf
    }
    
    // College Basketball
    if t.contains("college basketball") ||
       t.contains("ncaam") ||
       t.contains("cbb") ||
       t.contains("ncaa men's basketball") ||
       t.contains("march madness") {
        return .ncaam
    }
    
    if t.contains("nfl") || t.contains("sunday night football") || t.contains("monday night football") || t.contains("thursday night football") || t.contains("redzone") {
        return .nfl
    }
    
    if t.contains("nba") || t.contains("nba tv") { return .nba }
    if t.contains("mlb") || t.contains("baseball") || t.contains("world series") { return .mlb }
    if t.contains("nhl") || t.contains("hockey") || t.contains("stanley cup") { return .nhl }
    if t.contains("mls") || t.contains("major league soccer") { return .mls }
    if t.contains("premier league") || t.contains("epl") { return .epl }
    return nil
}

private func sanitizeNoise(_ string: String) -> String {
    var str = string
    let broadcastPatterns = [
        #"(?i)college football:?\s*"#,
        #"(?i)ncaa football:?\s*"#,
        #"(?i)cfb:?\s*"#,
        #"(?i)nfl:?\s*"#,
        #"(?i)nba:?\s*"#,
        #"(?i)mlb:?\s*"#,
        #"(?i)nhl:?\s*"#,
        #"(?i)mls:?\s*"#,
        #"(?i)premier league:?\s*"#,
        #"(?i)pregame:?\s*"#,
        #"(?i)postgame:?\s*"#,
        #"(?i)\(live\)"#,
        #"(?i)\[live\]"#,
        #"(?i)live:?\s*"#,
        #"(?i)\(replay\)"#,
        #"(?i)\[replay\]"#,
        #"(?i)\bHD\b"#,
        #"(?i)\b4K\b"#
    ]
    for pattern in broadcastPatterns {
        str = str.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return str.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func cleanTeamName(_ raw: String) -> String {
    var str = raw
    let rankPatterns = [
        #"(?i)#\d+\s*"#,
        #"(?i)\bno\.\s*\d+\s*"#,
        #"\(\d+\)\s*"#,
        #"\[\d+\]\s*"#,
        #"\(\d+-\d+(?:,\s*\d+-\d+)?\)\s*"#
    ]
    for pattern in rankPatterns {
        str = str.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return str.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func extractTeams(from text: String) -> (String, String, Bool)? {
    for pattern in Self.teamSeparators {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let matchRange = Range(match.range, in: text) {
                let teamA = String(text[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let teamB = String(text[matchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                let separatorStr = String(text[matchRange]).lowercased()
                let isAtFormat = separatorStr.contains("at") || separatorStr.contains("@")
                
                if !teamA.isEmpty && !teamB.isEmpty && teamA.count < 50 && teamB.count < 50 {
                    return (teamA, teamB, isAtFormat)
                }
            }
        }
    }
    return nil
}

// MARK: - Smart Team Name Matching

public func matchesTeam(queryName: String, candidateNames: [String]) -> Bool {
    let normalizedQuery = normalizeTeamString(queryName)
    let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
    let meaningfulQueryTokens = queryTokens.filter { !Self.sportsStopWords.contains($0) }

    for candidate in candidateNames {
        let normalizedCand = normalizeTeamString(candidate)
        if normalizedCand.isEmpty { continue }

        if normalizedCand == normalizedQuery ||
           normalizedCand.contains(normalizedQuery) ||
           normalizedQuery.contains(normalizedCand) {
            return true
        }

        let candTokens = normalizedCand.split(separator: " ").map(String.init)
        let meaningfulCandTokens = candTokens.filter { !Self.sportsStopWords.contains($0) }

        if !meaningfulQueryTokens.isEmpty && !meaningfulCandTokens.isEmpty {
            let intersection = Set(meaningfulQueryTokens).intersection(Set(meaningfulCandTokens))
            if !intersection.isEmpty {
                return true
            }
        }
    }
    return false
}

private func normalizeTeamString(_ input: String) -> String {
    var str = input.lowercased()
    str = str.replacingOccurrences(of: "&", with: "and")
    str = str.replacingOccurrences(of: "st.", with: "state")
    str = str.replacingOccurrences(of: "st ", with: "state ")
    str = str.replacingOccurrences(of: "fla st", with: "florida state")
    str = str.replacingOccurrences(of: "ole miss", with: "mississippi")
    str = str.replacingOccurrences(of: "uconn", with: "connecticut")
    str = str.replacingOccurrences(of: "pitt", with: "pittsburgh")
    str = str.replacingOccurrences(of: "usc", with: "southern california")
    str = str.replacingOccurrences(of: "bama", with: "alabama")
    str = str.replacingOccurrences(of: "lsu", with: "louisiana state")
    str = str.replacingOccurrences(of: "ucf", with: "central florida")
    str = str.replacingOccurrences(of: "byu", with: "brigham young")
    str = str.replacingOccurrences(of: "smu", with: "southern methodist")
    str = str.replacingOccurrences(of: "tcu", with: "texas christian")
    return str.filter { $0.isLetter || $0.isWhitespace || $0.isNumber }
        .trimmingCharacters(in: .whitespacesAndNewlines)
}


}

// MARK: - Remote Data & Resolution Manager

public actor SportsDataManager {
public static let shared = SportsDataManager()

private var cache: [MatchQuery: (score: LiveGameScore?, timestamp: Date)] = [:]
private let cacheTTL: TimeInterval = 10.0

private init() {}

public func resolveLiveScore(for query: MatchQuery) async -> LiveGameScore? {
    if let cached = cache[query], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
        return cached.score
    }

    let score = await fetchLiveScoreFromAPI(for: query)
    cache[query] = (score, Date())
    return score
}

private func fetchLiveScoreFromAPI(for query: MatchQuery) async -> LiveGameScore? {
    let dateStr = formatDateForAPI(query.broadcastDate)
    
    var endpoint = "https://site.api.espn.com/apis/site/v2/sports/\(query.league.rawValue)/scoreboard?dates=\(dateStr)&limit=250"
    if query.league == .ncaaf {
        endpoint += "&groups=80"
    } else if query.league == .ncaam {
        endpoint += "&groups=50"
    }
    
    if let score = await queryScoreboard(urlStr: endpoint, query: query) {
        return score
    }
    
    var fallbackEndpoint = "https://site.api.espn.com/apis/site/v2/sports/\(query.league.rawValue)/scoreboard?limit=250"
    if query.league == .ncaaf {
        fallbackEndpoint += "&groups=80"
    } else if query.league == .ncaam {
        fallbackEndpoint += "&groups=50"
    }
    
    if let score = await queryScoreboard(urlStr: fallbackEndpoint, query: query) {
        return score
    }

    if query.league == .ncaaf {
        let allDivisionsEndpoint = "https://site.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard?dates=\(dateStr)&limit=250"
        if let score = await queryScoreboard(urlStr: allDivisionsEndpoint, query: query) {
            return score
        }
    }

    return nil
}

private func queryScoreboard(urlStr: String, query: MatchQuery) async -> LiveGameScore? {
    guard let url = URL(string: urlStr) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 6

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            return nil
        }

        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let comp = competitions.first,
                  let competitors = comp["competitors"] as? [[String: Any]] else {
                continue
            }

            guard let homeComp = competitors.first(where: { ($0["homeAway"] as? String) == "home" }),
                  let awayComp = competitors.first(where: { ($0["homeAway"] as? String) == "away" }) else {
                continue
            }

            let homeTeamData = homeComp["team"] as? [String: Any]
            let awayTeamData = awayComp["team"] as? [String: Any]

            let homeDisplayName = homeTeamData?["displayName"] as? String ?? ""
            let homeShortName = homeTeamData?["shortDisplayName"] as? String ?? homeDisplayName
            let homeAbbr = homeTeamData?["abbreviation"] as? String ?? String(homeDisplayName.prefix(3)).uppercased()
            let homeLocation = homeTeamData?["location"] as? String ?? ""
            let homeNameOnly = homeTeamData?["name"] as? String ?? ""

            let awayDisplayName = awayTeamData?["displayName"] as? String ?? ""
            let awayShortName = awayTeamData?["shortDisplayName"] as? String ?? awayDisplayName
            let awayAbbr = awayTeamData?["abbreviation"] as? String ?? String(awayDisplayName.prefix(3)).uppercased()
            let awayLocation = awayTeamData?["location"] as? String ?? ""
            let awayNameOnly = awayTeamData?["name"] as? String ?? ""

            let matchesHome = SportsMatchEngine.shared.matchesTeam(
                queryName: query.homeTeamRaw,
                candidateNames: [homeDisplayName, homeShortName, homeAbbr, homeLocation, homeNameOnly]
            )
            let matchesAway = SportsMatchEngine.shared.matchesTeam(
                queryName: query.awayTeamRaw,
                candidateNames: [awayDisplayName, awayShortName, awayAbbr, awayLocation, awayNameOnly]
            )

            if matchesHome && matchesAway {
                let homeScore = Int(homeComp["score"] as? String ?? "0") ?? 0
                let awayScore = Int(awayComp["score"] as? String ?? "0") ?? 0

                let homeRank = extractRank(from: homeComp)
                let awayRank = extractRank(from: awayComp)

                let homeLines = extractLineScores(from: homeComp)
                let awayLines = extractLineScores(from: awayComp)

                let homeLogo = extractTeamLogo(from: homeTeamData)
                let awayLogo = extractTeamLogo(from: awayTeamData)

                let homeRecord = extractTeamRecord(from: homeComp)
                let awayRecord = extractTeamRecord(from: awayComp)

                let status = comp["status"] as? [String: Any]
                let statusType = status?["type"] as? [String: Any]
                let shortDetail = statusType?["shortDetail"] as? String ?? "Live"
                let state = statusType?["state"] as? String ?? "pre"

                let isPre = (state == "pre")
                let isLive = (state == "in")
                let isFinal = (state == "post")

                let venue = (comp["venue"] as? [String: Any])?["fullName"] as? String
                let broadcasts = comp["broadcasts"] as? [[String: Any]]
                let networkName = (broadcasts?.first?["names"] as? [String])?.first

                // Odds & spread for pregame preview
                var oddsDetail: String?
                var overUnderVal: String?
                if let oddsArr = comp["odds"] as? [[String: Any]], let primaryOdds = oddsArr.first {
                    oddsDetail = primaryOdds["details"] as? String
                    if let ou = primaryOdds["overUnder"] as? Double {
                        overUnderVal = "O/U \(Int(ou))"
                    } else if let ouStr = primaryOdds["overUnder"] as? String {
                        overUnderVal = "O/U \(ouStr)"
                    }
                }

                return LiveGameScore(
                    id: event["id"] as? String ?? UUID().uuidString,
                    league: query.league,
                    homeTeamName: homeShortName,
                    homeTeamAbbr: homeAbbr,
                    homeScore: homeScore,
                    homeRank: homeRank,
                    homeRecord: homeRecord,
                    homeLogoURL: homeLogo,
                    homeLineScores: homeLines,
                    awayTeamName: awayShortName,
                    awayTeamAbbr: awayAbbr,
                    awayScore: awayScore,
                    awayRank: awayRank,
                    awayRecord: awayRecord,
                    awayLogoURL: awayLogo,
                    awayLineScores: awayLines,
                    statusDisplay: shortDetail,
                    isLive: isLive,
                    isFinal: isFinal,
                    isPreGame: isPre,
                    startTimeDisplay: shortDetail,
                    venueName: venue,
                    broadcastNetwork: networkName,
                    oddsSummary: oddsDetail,
                    overUnder: overUnderVal
                )
            }
        }
    } catch {
        return nil
    }
    return nil
}

private func extractRank(from competitor: [String: Any]) -> Int? {
    if let curated = competitor["curatedRank"] as? [String: Any],
       let cur = curated["current"] as? Int, cur > 0, cur <= 25 {
        return cur
    }
    if let r = competitor["rank"] as? Int, r > 0, r <= 25 {
        return r
    }
    return nil
}

private func extractTeamLogo(from teamData: [String: Any]?) -> URL? {
    guard let team = teamData else { return nil }
    if let logoStr = team["logo"] as? String, let url = URL(string: logoStr) {
        return url
    }
    if let logos = team["logos"] as? [[String: Any]],
       let firstHref = logos.first?["href"] as? String,
       let url = URL(string: firstHref) {
        return url
    }
    return nil
}

private func extractTeamRecord(from competitor: [String: Any]) -> String? {
    guard let records = competitor["records"] as? [[String: Any]] else { return nil }
    if let total = records.first(where: { ($0["type"] as? String) == "total" }) {
        return total["summary"] as? String ?? total["displayValue"] as? String
    }
    return records.first?["summary"] as? String ?? records.first?["displayValue"] as? String
}

private func extractLineScores(from competitor: [String: Any]) -> [Int] {
    guard let lines = competitor["linescores"] as? [[String: Any]] else { return [] }
    return lines.compactMap { dict in
        if let val = dict["value"] as? Double { return Int(val) }
        if let val = dict["value"] as? Int { return val }
        return nil
    }
}

private func formatDateForAPI(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    formatter.timeZone = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -18000)
    return formatter.string(from: date)
}


}
