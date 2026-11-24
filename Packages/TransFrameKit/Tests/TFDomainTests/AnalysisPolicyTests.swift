import Foundation
import Testing
import TFDomain

@Suite("Analysis validation and engine policy")
struct AnalysisPolicyTests {
    @Test func rejectsWrongParentMissingChildrenAndMismatchedReadingOrder() {
        let parent = BlockID()
        let nested = BlockID()
        let absent = BlockID()
        let box = DocumentRect(x: 0, y: 0, width: 80, height: 20)
        let first = TextSegment(text: "First", box: box, parent: nested)
        let second = TextSegment(text: "Second", box: box, parent: parent)
        let orphan = TextSegment(text: "Orphan", box: box, parent: absent)
        let loose = TextSegment(text: "Loose", box: box)
        let root = ContentBlock(
            id: parent, kind: .paragraph, box: box, children: [.block(nested), .segment(second.id), .segment(loose.id), .block(absent)]
        )
        let child = ContentBlock(id: nested, kind: .paragraph, box: box, parent: parent, children: [.segment(first.id), .segment(SegmentID())])
        let issues = StructureValidation.issues(segments: [second, first, orphan, loose], blocks: [root, child])
        #expect(issues.contains(.unknownChild(nested)))
        #expect(issues.contains(.unknownChild(parent)))
        #expect(issues.contains(.missingParent(orphan.id)))
        #expect(issues.contains(.parentMismatch(loose.id)))
        #expect(issues.contains(.readingOrderMismatch))
        #expect(StructureValidation.issues(segments: [first, loose], blocks: []) == [.missingParent(first.id)])
    }

    @Test func classifierPrefersConfirmedCardsAndIDsOverOverlappingPhoneMatches() {
        let pan = "4111 1111 1111 1111"
        let exampleSSN = "078-05-1120"
        let syntheticID = "000000000000000001"
        let fakeToken = "QwErTyUiOpAsDfGhJkLzXcVbNm0123456789"
        let text = "🧾 Card \(pan)\nSSN \(exampleSSN)\nID \(syntheticID)\nToken \(fakeToken)"
        let matches = SensitiveTextClassifier.matches(in: text)
        #expect(matches.map(\.category) == [.paymentCard, .nationalID, .nationalID, .apiKey])
        #expect(matches.map { String(text[$0.range]) } == [pan, exampleSSN, syntheticID, fakeToken])
        let nearMiss = SensitiveTextClassifier.matches(in: "4111 1111 1111 1112; AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        #expect(!nearMiss.contains { $0.category == .paymentCard || $0.category == .apiKey })
    }

    @Test(arguments: [
        ("[::1]", EngineLocality.onDevice), ("fd00::1234", .localNetwork), ("fe80::ab", .localNetwork), ("2001:db8::1", .cloud),
    ])
    func endpointLocalityClassifiesIPv6WithoutDNS(host: String, locality: EngineLocality) {
        #expect(EngineLocality.classify(host: host) == locality)
    }

    @Test func versionRequirementUsesSemanticVersionAndAllowsUngatedProvider() {
        let requirements = EngineRequirements(minimumOS: OSVersion(26, 2))
        #expect(!requirements.isSupported(on: OSVersion(26, 1, 9)))
        #expect(requirements.isSupported(on: OSVersion(26, 2)))
        #expect(requirements.isSupported(on: OSVersion(26, 2, 1)))
        #expect(EngineRequirements().isSupported(on: OSVersion(15)))
        #expect(OSVersion(26, 2, 1).description == "26.2.1")
    }

    @Test func transportCancellationRemainsSilentAndProviderErrorsKeepTheirIdentity() {
        let cancelled = AppError.from(URLError(.cancelled))
        #expect(cancelled.isCancellation)
        #expect(cancelled.userMessage.presentation == .silent)
        let providerError = EngineError.rateLimited(.deepl, retryAfter: .seconds(2))
        #expect(providerError.engine == .deepl)
        #expect(EngineError.credentialLocked.engine == nil)
        #expect(AppError.from(AppError.engine(providerError)) == .engine(providerError))
        #expect(AppError.from(URLError(.unsupportedURL)).leafKey == "invariant")
    }
}
