import Foundation
import SwiftData

/// Assetに付与された分類タグ
@Model
final class AssetTag {
    var asset: Asset?
    var tag: String
    var confidence: Float

    init(tag: String, confidence: Float = 1.0) {
        self.tag = tag
        self.confidence = confidence
    }
}
