//
//  DemoChannels.swift
//  LiveFin
//
//  Created by KPGamingz on 9/10/25.
//

import Foundation
import SwiftUI

struct DemoChannel: Identifiable, Codable {
    let id: String
    let name: String
    let number: String
    let imageName: String
    let description: String
}

struct DemoChannelsData {
    static let channels: [DemoChannel] = [
        DemoChannel(id: "1", name: "Demo News", number: "101", imageName: "newspaper", description: "24/7 news coverage for demo purposes."),
        DemoChannel(id: "2", name: "Demo Sports", number: "102", imageName: "sportscourt", description: "Live sports highlights and demo games."),
        DemoChannel(id: "3", name: "Demo Kids", number: "103", imageName: "person.3.sequence", description: "Fun and educational content for kids."),
        DemoChannel(id: "4", name: "Demo Movies", number: "104", imageName: "film", description: "Blockbuster movies for demo viewing."),
        DemoChannel(id: "5", name: "Demo Music", number: "105", imageName: "music.note", description: "Non-stop music and demo concerts.")
    ]
}
