//
//  MediaComponents.swift
//  LiveFin
//
//  Created by KPGamingz on 7/17/26.
//


import SwiftUI
import UIKit

// MARK: - Cross-Platform Color Helpers

extension Color {
    /// `UIColor.secondarySystemBackground` isn't available on tvOS, so this
    /// falls back to a comparable translucent gray there.
    static var libFinSecondaryBackground: Color {
        #if os(tvOS)
        return Color.gray.opacity(0.2)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }
}

// MARK: - DTOs

struct JFViewDto: Identifiable, Decodable {
    let Id: String
    let Name: String
    let CollectionType: String?
    let ImageTags: [String: String]?
    
    var id: String { Id }
    var primaryImageTag: String? { ImageTags?["Primary"] }
}

struct JFUserData: Decodable, Hashable {
    let PlaybackPositionTicks: Int64?
    let Played: Bool?
}

struct JFItemDto: Identifiable, Decodable, Hashable {
    let Id: String
    let Name: String
    let `Type`: String
    let Overview: String?
    let ImageTags: [String: String]?
    let BackdropImageTags: [String]?
    let RunTimeTicks: Int64?
    let Genres: [String]?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    var UserData: JFUserData?
    
    // Additional Metadata
    let ProductionYear: Int?
    let OfficialRating: String?
    let SeasonId: String? // Added for season mapping
    let SeriesName: String? // Parent series content title
    let SeriesId: String? // Parent series ID
    
    var id: String { Id }
    
    var primaryImageTag: String? { ImageTags?["Primary"] }
    var backdropImageTag: String? { BackdropImageTags?.first }
    var logoImageTag: String? { ImageTags?["Logo"] }
    
    // Helper to format runtime to minutes
    var runtimeMinutes: Int? {
        guard let ticks = RunTimeTicks else { return nil }
        return Int(ticks / 600_000_000)
    }
}

struct JFPersonDto: Decodable, Identifiable {
    var id: String { Id ?? UUID().uuidString }
    let Id: String?
    let Name: String?
    let Role: String?
    let type: String? // "Actor", "Director", etc.
    let PrimaryImageTag: String?
    let ImageTags: [String: String]?
    
    // Additional fields for detail view
    var Overview: String?
    var PremiereDate: String?
    
    var resolvedPrimaryImageTag: String? {
        PrimaryImageTag ?? ImageTags?["Primary"]
    }
    
    enum CodingKeys: String, CodingKey {
        case Id
        case Name
        case Role
        case type = "Type"
        case PrimaryImageTag
        case ImageTags
        case Overview
        case PremiereDate
    }
}

// MARK: - Library Components (from LibraryView.swift)

struct HorizontalLibrariesRow: View {
    let views: [JFViewDto]
    @EnvironmentObject private var appState: AppState

    private func rainbowColor(for index: Int) -> Color {
        let hue = Double(index) / Double(max(views.count, 1))
        return Color(hue: hue, saturation: 0.8, brightness: 1.0)
    }
    
    private func iconFor(view: JFViewDto) -> String {
        let type = view.CollectionType?.lowercased() ?? ""
        if type == "movies" || view.Name.lowercased().contains("movie") { return "film" }
        if type == "tvshows" || view.Name.lowercased().contains("tv") { return "tv" }
        return "play.rectangle.on.rectangle" // Generic Mixed/HomeVideos Icon
    }

    var body: some View {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: 8) {
                ForEach(Array(views.enumerated()), id: \.element.id) { index, view in
                    
                    NavigationLink(destination: LibraryCategoryView(viewDto: view).environmentObject(appState)) {
                        Group {
                            // Library Image or Fallback View
                            if let tag = view.primaryImageTag,
                               let url = URL(string: "\(base)/Items/\(view.Id)/Images/Primary?tag=\(tag)&maxWidth=400") {
                                CachedAsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    case .failure, .empty:
                                        fallbackView(for: view, index: index)
                                    @unknown default:
                                        fallbackView(for: view, index: index)
                                    }
                                }
                            } else {
                                fallbackView(for: view, index: index)
                            }
                        }
                        .frame(width: 180, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel(Text(view.Name))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .frame(minHeight: 110)
        }
    }
    
    @ViewBuilder
    private func fallbackView(for view: JFViewDto, index: Int) -> some View {
        ZStack {
            // Gate on both platforms explicitly — `#available(iOS 26.0, *)` alone is
            // ignored on a tvOS build and evaluates true on ANY tvOS version via the
            // wildcard, which would call glassEffect on tvOS versions that don't have it.
            if #available(iOS 26.0, tvOS 26.0, *) {
                Rectangle() // The clipShape handles the cornerRadius
                    .glassEffect(.regular.tint(rainbowColor(for: index).opacity(0.45)).interactive(), in: .rect(cornerRadius: 16.0))
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
            
            VStack(spacing: 8) {
                Image(systemName: iconFor(view: view))
                    .font(.title) // Increased icon size
                    .foregroundColor(.white)
                Text(view.Name)
                    .font(.system(size: 15, weight: .bold)) // Increased text size
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
    }
}

struct DemoLibraryRowItem: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 32)
            Text(title)
                .font(.title3.weight(.medium))
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct LibraryPosterCard: View {
    let item: JFItemDto
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.libFinSecondaryBackground
                
                if let tag = item.primaryImageTag,
                   let url = URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(tag)&maxWidth=400") {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            fallbackPlaceholder
                        case .empty:
                            ProgressView()
                                .scaleEffect(0.8)
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    fallbackPlaceholder
                }
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            
            Text(item.Name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: 34, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
    
    @ViewBuilder
    private var fallbackPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(item.Name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.libFinSecondaryBackground)
    }
}

// MARK: - Media Detail Components (from MediaView.swift)

struct RelatedItemCard: View {
    let item: JFItemDto
    let baseServerURL: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.libFinSecondaryBackground)
                
                if let tag = item.primaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(item.Id)/Images/Primary?tag=\(tag)&maxWidth=300") {
                    CachedAsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 180)
                                .clipped()
                        } else if phase.error != nil {
                            fallbackPlaceholder
                        } else {
                            ProgressView()
                        }
                    }
                } else {
                    fallbackPlaceholder
                }
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1.5)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.Name)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let year = item.ProductionYear {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("")
                        .font(.caption2)
                }
            }
            .frame(width: 120, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
    
    private var fallbackPlaceholder: some View {
        VStack {
            Image(systemName: item.Type == "Series" ? "tv" : "film")
                .foregroundColor(.gray)
                .font(.system(size: 28))
        }
        .frame(width: 120, height: 180)
    }
}

struct DynamicBackdropImageView: View {
    let url: URL?
    @Binding var rawColor: Color?
    let height: CGFloat
    
    @State private var image: UIImage? = nil
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.libFinSecondaryBackground)
                    .frame(height: height)
                
                if isLoading {
                    ProgressView()
                }
            }
        }
        .task(id: url) {
            guard let url = url else { return }
            isLoading = true
            
            if let cached = ImageCacheManager.shared.imageIfCached(for: url) {
                self.image = cached
                isLoading = false
                if let extractedColor = await cached.bottomAverageColor() {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.rawColor = extractedColor
                    }
                }
                return
            }
            
            await withCheckedContinuation { continuation in
                ImageCacheManager.shared.load(url) { fetchedImage in
                    if let fetchedImage = fetchedImage {
                        self.image = fetchedImage
                        Task {
                            if let extractedColor = await fetchedImage.bottomAverageColor() {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    self.rawColor = extractedColor
                                }
                            }
                        }
                    }
                    isLoading = false
                    continuation.resume()
                }
            }
        }
    }
}

struct EpisodeRowView: View {
    let episode: JFItemDto
    let baseServerURL: String
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        let thumbWidth: CGFloat = horizontalSizeClass == .compact ? 120 : 160
        let thumbHeight: CGFloat = thumbWidth * (9/16)
        
        HStack(alignment: .top, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.libFinSecondaryBackground)
                
                if let tag = episode.primaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(episode.Id)/Images/Primary?tag=\(tag)&maxWidth=300") {
                    CachedAsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                 .aspectRatio(contentMode: .fill)
                                 .frame(width: thumbWidth, height: thumbHeight)
                                 .clipped()
                        } else if phase.error != nil {
                            VStack {
                                Image(systemName: "tv")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 24))
                            }
                            .frame(width: thumbWidth, height: thumbHeight)
                        } else {
                            ProgressView()
                                .frame(width: thumbWidth, height: thumbHeight)
                        }
                    }
                } else {
                    VStack {
                        Image(systemName: "tv")
                            .foregroundColor(.gray)
                            .font(.system(size: 24))
                    }
                    .frame(width: thumbWidth, height: thumbHeight)
                }
                
                if episode.UserData?.Played == true {
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.6))
                            .frame(width: 24, height: 24)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                
                if let ticks = episode.UserData?.PlaybackPositionTicks, ticks > 0,
                   let total = episode.RunTimeTicks, total > 0 {
                    let progress = CGFloat(ticks) / CGFloat(total)
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: thumbWidth * min(progress, 1.0), height: 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(episode.Name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                if let minutes = episode.runtimeMinutes {
                    Text("\(minutes) min")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let overview = episode.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct CastMemberCard: View {
    let person: JFPersonDto
    let baseServerURL: String
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.libFinSecondaryBackground)
                
                if let tag = person.resolvedPrimaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(person.Id ?? "")/Images/Primary?tag=\(tag)&maxWidth=200") {
                    CachedAsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                 .aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            Image(systemName: "person.fill").foregroundColor(.gray)
                        } else {
                            ProgressView()
                        }
                    }
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 1.5)
            
            VStack(spacing: 2) {
                Text(person.Name ?? "Unknown")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                if let role = person.Role, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 100)
        }
    }
}

// MARK: - Extensions

extension Color {
    func blended(with other: Color, ratio: CGFloat) -> Color {
        let uiColor1 = UIColor(self)
        let uiColor2 = UIColor(other)
        
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        
        guard uiColor1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              uiColor2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return self
        }
        
        let clampedRatio = min(max(ratio, 0.0), 1.0)
        
        return Color(
            .sRGB,
            red: Double(r1 * (1 - clampedRatio) + r2 * clampedRatio),
            green: Double(g1 * (1 - clampedRatio) + g2 * clampedRatio),
            blue: Double(b1 * (1 - clampedRatio) + b2 * clampedRatio),
            opacity: Double(a1 * (1 - clampedRatio) + a2 * clampedRatio)
        )
    }
}

extension UIImage {
    func bottomAverageColor() async -> Color? {
        guard let cgImage = self.cgImage else { return nil }
        let cgWidth = cgImage.width
        let cgHeight = cgImage.height
        
        guard cgWidth > 0 && cgHeight > 0 else { return nil }
        
        let sampleRect = CGRect(
            x: 0,
            y: CGFloat(cgHeight) * 0.9,
            width: CGFloat(cgWidth),
            height: CGFloat(cgHeight) * 0.1
        )
        
        guard let cropped = cgImage.cropping(to: sampleRect) else { return nil }
        
        return await Task.detached(priority: .userInitiated) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixelData = [UInt8](repeating: 0, count: 4)
            
            guard let context = CGContext(
                data: &pixelData,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            
            let r = Double(pixelData[0]) / 255.0
            let g = Double(pixelData[1]) / 255.0
            let b = Double(pixelData[2]) / 255.0
            let a = Double(pixelData[3]) / 255.0
            
            return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        }.value
    }
}
