//
//  TVChannel.swift
//  LiveFin
//
//  Created by KPGamingz on 7/17/26.
//

import Foundation

struct TVChannel: Identifiable, Codable, Hashable {
    let id: String
    var name: String?
    var number: String?
    var imageUrl: String?
}
