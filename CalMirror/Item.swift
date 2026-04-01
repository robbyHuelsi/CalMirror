//
//  Item.swift
//  CalMirror
//
//  Created by Robert Hülsmann on 01.04.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
