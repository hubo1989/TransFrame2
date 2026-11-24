import AppKit
import Testing
import TFDomain
import TFDomainTestSupport
import TFRenderInfra
@testable import TFWorkspaceUI

/// Annotation interaction against the real store, planner and renderer (canvas 800×500 pt showing 1600×1000 px @2x:
/// a view point maps to twice its coordinates in document pixels).
@Suite("Annotation editor")
@MainActor
struct AnnotationEditorTests {
    private func rect(_ s: DocumentSession, _ id: AnnotationID) -> ShapeAnnotation? {
        if case .rectangle(let r)? = s.annotation(id) { r } else { nil }
    }

    /// Draws a rectangle from view (100,100) to (200,160): document rect (200,200,200,120).
    private func drawRect(_ h: CanvasHarness) async throws -> (DocumentSession, AnnotationID) {
        h.editor.tool = .rectangle
        let s = try await h.drawGesture(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160))
        return (s, try #require(s.annotations.last?.id))
    }

    @Test func newAnnotationStaysSelectedAndShowsWithoutWaitingForTheStore() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        h.editor.tool = .rectangle
        let before = try await h.session().editRevision
        h.down(CGPoint(x: 100, y: 100))
        h.drag(CGPoint(x: 150, y: 130))
        h.drag(CGPoint(x: 200, y: 160))
        h.up(CGPoint(x: 200, y: 160))
        // Between mouse-up and the store echo the committed shape is drawn on the overlay and already selected.
        let pending = try #require(h.editor.pending.first?.annotation)
        #expect(h.editor.pending.count == 1)
        #expect(h.editor.selectedID == pending.id)
        #expect(h.editor.chromeTarget?.id == pending.id)
        let after = try await h.waitForRevision(before + 1)
        await h.waitForRender(revision: after.editRevision)
        #expect(h.editor.pending.isEmpty)
        #expect(after.annotations.count == 1)
        #expect(rect(after, pending.id)?.rect == DocumentRect(x: 200, y: 200, width: 200, height: 120))
        #expect(h.editor.selectedID == pending.id)
    }

    @Test func movedAnnotationStaysHiddenInRendersUntilTheMoveIsInTheImage() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let (drawn, id) = try await drawRect(h)
        h.editor.tool = nil
        #expect(h.editor.selectedID == id)
        h.down(CGPoint(x: 125, y: 100))
        h.drag(CGPoint(x: 135, y: 110))
        #expect(h.editor.renderExclusions(at: drawn.editRevision) == [id])
        h.drag(CGPoint(x: 145, y: 120))
        h.up(CGPoint(x: 145, y: 120))
        #expect(h.editor.hiddenID == nil)
        #expect(h.editor.renderExclusions(at: drawn.editRevision) == [id])
        #expect(h.editor.pending.first?.annotation?.bounds.minX == drawn.annotation(id)!.bounds.minX + 40)
        let moved = try await h.waitForRevision(drawn.editRevision + 1)
        await h.waitForRender(revision: moved.editRevision)
        #expect(h.editor.pending.isEmpty)
        #expect(h.editor.renderExclusions(at: moved.editRevision).isEmpty)
        #expect(rect(moved, id)?.rect.origin == DocumentPoint(x: 240, y: 240))
    }

    @Test func styleBarShowsTheSelectionAndChangesOnlyTheEditedField() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let (_, id) = try await drawRect(h)
        _ = h.editor.cancelStep() // selection
        _ = h.editor.cancelStep() // tool
        h.editor.setStyle { $0.lineWidth = 10 }
        #expect(h.editor.style.lineWidth == 10)
        // Click the top edge to select it again: the bar shows the rectangle's own width.
        h.down(CGPoint(x: 125, y: 100))
        h.up(CGPoint(x: 125, y: 100))
        #expect(h.editor.selectedID == id)
        #expect(h.editor.displayedStyle.lineWidth == 3)
        #expect(h.editor.styleControls == [.color, .lineWidth, .fill])
        let before = try await h.session().editRevision
        h.editor.setStyle { $0.color = AnnotationPalette.blue }
        #expect(h.editor.draft != nil)
        h.editor.flushStyle()
        let after = try await h.waitForRevision(before + 1)
        let restyled = try #require(rect(after, id))
        #expect(restyled.strokeColor == AnnotationPalette.blue)
        #expect(restyled.lineWidth == 6)
        #expect(h.editor.style.color == AnnotationPalette.blue)
        #expect(h.editor.style.lineWidth == 10)
        #expect(after.editRevision == before + 1)
    }

    @Test func fillFollowsTheStrokeUntilItIsSetOnItsOwn() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        h.editor.setStyle { $0.color = AnnotationPalette.blue }
        #expect(h.editor.style.fillColor == AnnotationPalette.blue.withAlpha(AnnotationStyle.autoFillAlpha))
        let custom = AnnotationPalette.green.withAlpha(0.6)
        h.editor.setStyle { $0.fillColor = custom }
        h.editor.setStyle { $0.color = AnnotationPalette.red }
        #expect(h.editor.style.fillColor == custom)
    }

    @Test func arrowKeysNudgeTheSelectionAndDeleteRemovesIt() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let (drawn, id) = try await drawRect(h)
        h.key("", keyCode: 124)
        var s = try await h.waitForRevision(drawn.editRevision + 1)
        #expect(rect(s, id)?.rect.origin == DocumentPoint(x: 202, y: 200))
        h.key("", keyCode: 125, flags: .shift)
        s = try await h.waitForRevision(s.editRevision + 1)
        #expect(rect(s, id)?.rect.origin == DocumentPoint(x: 202, y: 220))
        h.key("\u{7f}", keyCode: 51)
        s = try await h.waitForRevision(s.editRevision + 1)
        #expect(s.annotations.isEmpty)
        #expect(h.editor.selectedID == nil)
        #expect(!h.editor.handleKey("", keyCode: 124, modifiers: []))
    }

    @Test func numberLabelsCountPendingOnesAndFollowTheTextSize() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        h.editor.tool = .numberLabel
        h.down(CGPoint(x: 50, y: 50))
        h.up(CGPoint(x: 50, y: 50))
        h.down(CGPoint(x: 120, y: 50))
        h.up(CGPoint(x: 120, y: 50))
        let s = try await h.waitForRevision(2)
        let numbers = s.annotations.compactMap { if case .numberLabel(let n) = $0 { n.number } else { nil } }
        #expect(numbers == [1, 2], "\(numbers) rev \(s.editRevision) pending \(h.editor.pending.count)")
        let label = try #require(s.annotations.last)
        let bigger = AnnotationGeometry.restyle(label, with: { var st = h.editor.style; st.fontSize = 30; return st }(), scale: 2, fields: [.fontSize])
        if case .numberLabel(let n) = bigger { #expect(n.diameter == 96) } else { Issue.record("not a label") }
    }

    @Test func editingTextHidesTheOriginalAndCancelKeepsIt() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        h.editor.tool = .text
        h.down(CGPoint(x: 300, y: 200))
        #expect(h.editor.textEditing != nil)
        h.editor.textEditing?.text = "Hello"
        h.editor.commitText()
        var s = try await h.waitForRevision(1)
        await h.waitForRender(revision: s.editRevision)
        let id = try #require(s.annotations.first?.id)
        h.editor.tool = nil
        h.down(CGPoint(x: 305, y: 205), clicks: 2)
        #expect(h.editor.textEditing?.annotationID == id)
        #expect(h.editor.renderExclusions(at: s.editRevision) == [id])
        h.editor.cancelText()
        #expect(h.editor.hiddenID == nil)
        #expect(h.editor.pending.last?.annotation?.id == id)
        h.down(CGPoint(x: 305, y: 205), clicks: 2)
        h.editor.textEditing?.text = "Hello world"
        h.editor.commitText()
        s = try await h.waitForRevision(s.editRevision + 1)
        if case .text(let t)? = s.annotation(id) { #expect(t.text == "Hello world") } else { Issue.record("text missing") }
    }

    @Test func calloutPointerHasItsOwnHandle() {
        let callout = Annotation.callout(
            CalloutAnnotation(
                bubble: DocumentRect(x: 100, y: 100, width: 80, height: 40), pointer: DocumentPoint(x: 60, y: 180), text: "Hi", color: .black,
                fontSize: 16, fillColor: .white))
        #expect(AnnotationGeometry.handles(for: callout)[.pointer] == DocumentPoint(x: 60, y: 180))
        let aimed = AnnotationGeometry.resize(callout, handle: .pointer, to: DocumentPoint(x: 250, y: 20), constrain: false)
        guard case .callout(let c) = aimed else {
            Issue.record("not a callout")
            return
        }
        #expect(c.pointer == DocumentPoint(x: 250, y: 20))
        #expect(c.bubble == DocumentRect(x: 100, y: 100, width: 80, height: 40))
    }

    @Test func cursorsFollowToolsHandlesAndAnnotations() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let (_, _) = try await drawRect(h)
        #expect(h.editor.cursor(at: DocumentPoint(x: 200, y: 200)) == .resize(.topLeft))
        #expect(h.editor.cursor(at: DocumentPoint(x: 900, y: 900)) == .crosshair)
        h.editor.tool = .text
        #expect(h.editor.cursor(at: DocumentPoint(x: 900, y: 900)) == .iBeam)
        h.editor.tool = nil
        #expect(h.editor.cursor(at: DocumentPoint(x: 250, y: 200)) == .move)
        #expect(h.editor.cursor(at: DocumentPoint(x: 900, y: 900)) == .arrow)
    }

    @Test func toolHintsDropKeysTheHostReserves() {
        #expect(AnnotationTool.rectangle.shortcutKeys() == ["R", "1"])
        #expect(AnnotationTool.text.shortcutKeys(reserved: ["t", "p", "c"]) == ["8"])
        #expect(AnnotationTool.callout.shortcutKeys() == ["B"])
        #expect(AnnotationTool.redaction.styleControls.isEmpty)
        #expect(AnnotationTool.mosaic.styleControls == [.mosaic])
    }

    @Test func styleBarAppearsForToolsWithControlsAndForSelections() async {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        #expect(!h.editor.showsStyleBar)
        h.editor.tool = .redaction
        #expect(!h.editor.showsStyleBar)
        h.editor.tool = .arrow
        #expect(h.editor.showsStyleBar)
        h.editor.tool = nil
        h.editor.stylePinned = true
        #expect(h.editor.showsStyleBar)
        #expect(h.editor.styleControls == .all)
        #expect(h.editor.cancelStep())
        #expect(!h.editor.stylePinned)
    }

    @Test func rapidEditsEndWithTheLatestRevisionOnScreen() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let (drawn, id) = try await drawRect(h)
        for _ in 0..<12 { h.key("", keyCode: 124) }
        let s = try await h.waitForRevision(drawn.editRevision + 12)
        await h.waitForRender(revision: s.editRevision)
        #expect(rect(s, id)?.rect.origin == DocumentPoint(x: 224, y: 200))
        #expect(h.renderedRevisions.last == s.editRevision)
        #expect(h.editor.pending.isEmpty)
    }
}

@Suite("Overlay trimming")
@MainActor
struct OverlayTrimmingTests {
    /// Draws `annotation` into a 400×300 bitmap clipped to `clip` and returns the bytes.
    private func pixels(_ annotation: Annotation, clip: CGRect) -> [UInt8] {
        let context = TestImages.context(width: 400, height: 300)!
        context.clip(to: clip)
        let plan = RenderPlan(
            session: SessionID(), editRevision: 0, canvas: PixelSize(width: 400, height: 300), scale: 1, background: .transparent,
            layers: [.decorations([PlacedAnnotation(annotation: annotation, offsetX: 0, offsetY: 0)])],
            contentFrame: CanvasRect(x: 0, y: 0, width: 400, height: 300))
        TFRenderInfra.CoreGraphicsRenderer().draw(plan, base: TestImages.solid(width: 400, height: 300), in: context)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: context.bytesPerRow * 300))
    }

    @Test func trimmedStrokeDrawsTheSamePixelsInsideTheDirtyRegion() {
        let points = (0..<400).map { i in DocumentPoint(x: Double(i), y: 150 + sin(Double(i) / 9) * 100) }
        let stroke = Annotation.freehand(PathAnnotation(points: points, color: .black, lineWidth: 6))
        let clip = CGRect(x: 300, y: 40, width: 60, height: 220)
        let trimmed = DocumentCanvasView.trimmed(stroke, to: DocumentRect(clip))
        guard case .freehand(let path) = trimmed else {
            Issue.record("not a stroke")
            return
        }
        #expect(path.points.count < 100)
        // Same curve inside the region; allow one or two levels of anti-aliasing difference across CPU architectures.
        let difference = zip(pixels(trimmed, clip: clip), pixels(stroke, clip: clip)).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(difference <= 2)
        #expect(DocumentCanvasView.trimmed(stroke, to: DocumentRect(x: 0, y: 0, width: 400, height: 300)) == stroke)
    }
}

/// A selection across displays shows one document on several canvases driven by one editor (review: Codex P2).
@Suite("Mirrored canvases")
@MainActor
struct MirroredCanvasTests {
    @Test func everyCanvasDrawsTheEditsAndOnlyThePrimaryTakesText() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let mirror = DocumentCanvasView(render: h.render, sessionID: h.id, editor: h.editor)
        mirror.isMirror = true
        mirror.frame = h.canvas.frame
        h.window.contentView?.addSubview(mirror)
        mirror.update(try await h.session())
        h.observer.onChange = { [weak h, weak mirror] session in
            h?.canvas.update(session)
            mirror?.update(session)
        }
        for _ in 0..<200 where mirror.plan == nil { try await Task.sleep(for: .milliseconds(5)) }
        mirror.overlayDidDraw()
        h.editor.tool = .rectangle
        h.down(CGPoint(x: 100, y: 100))
        h.drag(CGPoint(x: 160, y: 140))
        #expect(!mirror.pendingOverlayDirty.isNull, "the mirror redraws the live draft too")
        h.up(CGPoint(x: 160, y: 140))
        let s = try await h.waitForRevision(1)
        for _ in 0..<200 where mirror.plan?.editRevision != s.editRevision { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mirror.plan?.editRevision == s.editRevision)
        h.editor.tool = .text
        h.down(CGPoint(x: 300, y: 300))
        #expect(h.canvas.subviews.contains { $0 is NSTextField })
        #expect(!mirror.subviews.contains { $0 is NSTextField })
        h.editor.cancelText()
    }
}
