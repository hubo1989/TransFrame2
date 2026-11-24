import Foundation
import Testing
import TFDomain
@testable import TFSystemInfra

@Suite("Update check outcome (ONB-05)")
struct UpdateFeedDecisionTests {
    private func feed(_ builds: [Int]) -> Data {
        let items = builds.map { "<item><sparkle:version>\($0)</sparkle:version><enclosure url=\"x\" /></item>" }.joined()
        return Data("<?xml version=\"1.0\"?><rss><channel>\(items)</channel></rss>".utf8)
    }

    @Test func missingFeedBeforeFirstReleaseIsUpToDate() {
        #expect(UpdateFeedDecision.outcome(status: 404, body: Data(), currentBuild: 40, currentVersion: "2.0.0") == .upToDate(version: "2.0.0"))
    }

    @Test func sameOrOlderBuildIsUpToDate() {
        #expect(UpdateFeedDecision.outcome(status: 200, body: feed([38, 40]), currentBuild: 40, currentVersion: "2.0.0") == .upToDate(version: "2.0.0"))
        #expect(UpdateFeedDecision.outcome(status: 200, body: feed([]), currentBuild: 40, currentVersion: "2.0.0") == .upToDate(version: "2.0.0"))
    }

    @Test func newerBuildHandsOverToSparkle() {
        #expect(UpdateFeedDecision.outcome(status: 200, body: feed([41]), currentBuild: 40, currentVersion: "2.0.0") == .updateAvailable)
        let attribute = Data("<rss><channel><item><enclosure sparkle:version=\"50\" url=\"x\"/></item></channel></rss>".utf8)
        #expect(UpdateFeedDecision.outcome(status: 200, body: attribute, currentBuild: 40, currentVersion: "2.0.0") == .updateAvailable)
    }

    @Test func serverErrorsAndNonFeedsAreUnavailable() {
        #expect(UpdateFeedDecision.outcome(status: 503, body: Data(), currentBuild: 1, currentVersion: "2.0.0") == .unavailable)
        let portal = Data("<html>captive portal</html>".utf8)
        #expect(UpdateFeedDecision.outcome(status: 200, body: portal, currentBuild: 1, currentVersion: "2.0.0") == .unavailable)
    }
}
