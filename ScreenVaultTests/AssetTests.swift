import Testing
@testable import ScreenVault

@Test func assetInitialization() {
    let asset = Asset(kind: .screenshot, sourceMode: .watch, sizeBytes: 1024)
    #expect(asset.kind == .screenshot)
    #expect(asset.sourceMode == .watch)
    #expect(asset.sizeBytes == 1024)
    #expect(!asset.assetID.isEmpty)
}
