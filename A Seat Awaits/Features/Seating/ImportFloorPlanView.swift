//
//  ImportFloorPlanView.swift
//  A Seat Awaits
//
//  Sheet for AI floor plan import — upload a photo, scan, or PDF of the venue's
//  floor plan and the `ai-import-floorplan` Edge Function (same consensus
//  vision pipeline as the web) rebuilds the room as canvas-ready tables and
//  fixtures. Three steps: upload → analyzing (20–60 s, rotating status) →
//  review (vector preview + detected summary + warnings) → apply, which
//  inserts the room to the right of any existing rooms.
//
//  Paid feature: any Standard/Premium Event Pass on this event, or the Pro
//  plan. The Edge Function enforces this server-side — the gate here keeps the
//  UI honest (see [[ios-paid-feature-gating]]).
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ImportFloorPlanView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step { case upload, analyzing, review }

    /// The floor plan file the user picked, normalized for upload.
    private struct PickedPlan: Equatable {
        let data: Data
        let name: String
        let contentType: String
        /// Rendered preview for raster files; nil for PDFs (document card instead).
        let preview: UIImage?
    }

    @State private var step: Step = .upload
    @State private var picked: PickedPlan?
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var errorMessage: String?
    @State private var result: AiFloorplanImportResponse?
    @State private var applying = false
    @State private var showingPaywall = false

    // Rotating status + eased progress while the vision consensus runs.
    @State private var analyzingPhraseIndex = 0
    @State private var analyzingProgress: Double = 0

    private static let maxFileBytes = 10 * 1024 * 1024
    /// Floor plans need legible detail (handwritten counts, scale bars) but the
    /// function caps uploads at 10 MB — 2400 px JPEG keeps both happy.
    private static let maxImageDimension: CGFloat = 2400

    /// Analysis takes 20–60 s — keep it alive with phrases that narrate what
    /// the extraction is actually doing (mirrors the web modal).
    private static let analyzingPhrases = [
        "Tracing the walls…",
        "Measuring the room…",
        "Reading the scale bar…",
        "Counting chairs around every table…",
        "Looking for the dance floor…",
        "Finding the head table…",
        "Squinting at handwritten notes…",
        "Checking the seating math…",
        "Straightening the photo…",
        "Double-checking every table…",
        "Good floor plans take a minute…",
        "Almost there…",
    ]

    private var aiAllowed: Bool { store.entitlement.aiImport }
    private var gateResolved: Bool { store.entitlementLoaded }

    private var planIsEmpty: Bool {
        guard let plan = result?.plan else { return true }
        return plan.tables.isEmpty && plan.shapes.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Brand.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        if gateResolved && !aiAllowed {
                            upgradeGate
                                .padding(.top, 24)
                        } else if step == .review, let result {
                            reviewContent(result)
                                .padding(.top, 16)
                        } else if gateResolved {
                            uploadContent
                                .padding(.top, 16)
                        } else {
                            ProgressView()
                                .padding(.top, 60)
                        }
                        Color.clear.frame(height: 96)
                    }
                    .padding(.horizontal, 20)
                }

                if gateResolved && aiAllowed {
                    footer
                }
            }
            .background(Brand.canvas)
            .safeAreaInset(edge: .top) {
                SheetHeader(title: "Import Your Floor Plan", onCancel: handleClose)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .background(Brand.canvas)
            }
            .navigationBarHidden(true)
            .interactiveDismissDisabled(step == .analyzing || applying)
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: Self.allowedTypes,
                          allowsMultipleSelection: false) { outcome in
                handleFileImport(outcome)
            }
            .onChange(of: photoItem) { _, item in
                if let item { Task { await loadPhoto(item) } }
            }
            .sheet(isPresented: $showingPaywall, onDismiss: {
                Task { await store.loadEntitlement() }
            }) {
                if let supabase = appState.supabase {
                    PaywallView(supabase: supabase, appState: appState,
                                mode: .plans(eventId: store.event.id))
                }
            }
            .task { await store.loadEntitlement() }
        }
    }

    // MARK: - Upgrade gate

    private var upgradeGate: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Brand.plumChipFillSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .scaledFont(size: 26, weight: .semibold)
                    .foregroundStyle(Brand.purple)
            }
            .accessibilityHidden(true)
            Text("Available on paid plans")
                .scaledFont(size: 17, weight: .bold)
                .foregroundStyle(Brand.textPrimary)
            Text("AI floor plan import is included with a Standard or Premium Event Pass, or with Pro. Upload a photo of your venue's floor plan and we'll rebuild the room for you.")
                .scaledFont(size: 13)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showingPaywall = true
            } label: {
                Label("View Plans", systemImage: "sparkles")
                    .scaledFont(size: 15, weight: .bold)
            }
            .buttonStyle(.primaryBrand)
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Upload step

    private var uploadContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Upload a photo, scan, or PDF of your venue's floor plan and we'll rebuild the room for you. We'll do our best to get it right, and everything's easy to adjust after.")
                .scaledFont(size: 13)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            dropZone
                .padding(.top, 16)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Brand.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Label("Best results: a straight-on photo or scan with a scale bar or written dimensions.",
                  systemImage: "info.circle")
                .scaledFont(size: 12)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            if step == .analyzing {
                analyzingIndicator
            } else if let picked {
                if let preview = picked.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Brand.plumChipFillSoft)
                            .frame(width: 64, height: 64)
                        Image(systemName: "doc.richtext")
                            .scaledFont(size: 26, weight: .semibold)
                            .foregroundStyle(Brand.purple)
                    }
                    Text("PDF ready to analyze")
                        .scaledFont(size: 12)
                        .foregroundStyle(Brand.textSecondary)
                }
                Text(picked.name)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                pickButtons(compact: true)
            } else {
                ZStack {
                    Circle()
                        .fill(Brand.plumChipFillSoft)
                        .frame(width: 56, height: 56)
                    Image(systemName: "photo.badge.arrow.down")
                        .scaledFont(size: 22, weight: .semibold)
                        .foregroundStyle(Brand.purple)
                }
                Text("Add your floor plan")
                    .scaledFont(size: 15, weight: .bold)
                    .foregroundStyle(Brand.textPrimary)
                Text("PNG, JPEG, WebP, or PDF · up to 10 MB\nPhotos and scans work great")
                    .scaledFont(size: 12)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
                pickButtons(compact: false)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Brand.plumChipFillSoft.opacity(scheme == .dark ? 0.4 : 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Brand.plumChipFill,
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private func pickButtons(compact: Bool) -> some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(compact ? "Photos" : "Choose Photo", systemImage: "photo")
                    .scaledFont(size: 13, weight: .semibold)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Brand.primaryFill,
                                in: Capsule())
                    .foregroundStyle(.white)
            }
            Button {
                showFileImporter = true
            } label: {
                Label(compact ? "Files" : "Browse Files", systemImage: "folder")
                    .scaledFont(size: 13, weight: .semibold)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .overlay(Capsule().strokeBorder(Brand.accent, lineWidth: 1.5))
                    .foregroundStyle(Brand.accent)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Analyzing

    private var analyzingIndicator: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Brand.plumChipFill, lineWidth: 5)
                    .frame(width: 64, height: 64)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Brand.purple, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(step == .analyzing && !reduceMotion ? 360 : 0))
                    .animation(reduceMotion ? nil
                               : .linear(duration: 1.1).repeatForever(autoreverses: false),
                               value: step == .analyzing)
                Image(systemName: "wand.and.stars")
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(Brand.purple)
            }
            Text("Reading your floor plan…")
                .scaledFont(size: 15, weight: .bold)
                .foregroundStyle(Brand.textPrimary)
            Text(Self.analyzingPhrases[analyzingPhraseIndex])
                .scaledFont(size: 12)
                .foregroundStyle(Brand.textSecondary)
                .transition(.opacity)
                .id(analyzingPhraseIndex)
                .animation(.easeInOut(duration: 0.3), value: analyzingPhraseIndex)

            // No real progress events from the vision call — ease toward 92%
            // so the bar always moves but never lies about being done.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.plumChipFill)
                    Capsule()
                        .fill(Brand.purple)
                        .frame(width: geo.size.width * analyzingProgress / 100)
                        .animation(.easeOut(duration: 0.5), value: analyzingProgress)
                }
            }
            .frame(width: 200, height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Analyzing progress")
            .accessibilityValue("\(Int(analyzingProgress)) percent")
        }
        .padding(.vertical, 8)
    }

    // MARK: - Review step

    private func reviewContent(_ result: AiFloorplanImportResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            planPreview(result)

            detectedCard(result)

            Button("Use a Different Image") {
                startOver()
            }
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(Brand.accent)
            .underline()
            .frame(minHeight: 44)

            Label("Our AI reads your plan as faithfully as it can, but nobody knows your venue like you do. Give the layout a quick once-over after importing. Every table and fixture can be dragged, resized, and renamed until it's just right.",
                  systemImage: "info.circle")
                .scaledFont(size: 12)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Vector preview of the extracted plan — room outline (dashed), fixtures
    /// (neutral), tables (plum, capacity inside) — scaled to fit.
    private func planPreview(_ result: AiFloorplanImportResponse) -> some View {
        let roomW = max(result.roomWidthFt * TableScale.pointsPerFoot, 1)
        let roomH = max(result.roomHeightFt * TableScale.pointsPerFoot, 1)
        return Canvas { context, size in
            let pad: CGFloat = 8
            let scale = min((size.width - pad * 2) / roomW,
                            (size.height - pad * 2) / roomH)
            let originX = (size.width - roomW * scale) / 2
            let originY = (size.height - roomH * scale) / 2
            func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
                CGRect(x: originX + x * scale, y: originY + y * scale,
                       width: w * scale, height: h * scale)
            }

            // Room outline.
            let roomRect = rect(0, 0, roomW, roomH)
            context.stroke(Path(roundedRect: roomRect, cornerRadius: 3),
                           with: .color(Brand.textSecondary.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

            // Fixtures.
            for shape in result.plan.shapes {
                let r = rect(shape.positionX, shape.positionY, shape.width, shape.height)
                let isRound = shape.type == "circle" || shape.type == "oval"
                var path = isRound ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: 3)
                if shape.rotation != 0 && !isRound {
                    let transform = CGAffineTransform(translationX: r.midX, y: r.midY)
                        .rotated(by: shape.rotation * .pi / 180)
                        .translatedBy(x: -r.midX, y: -r.midY)
                    path = path.applying(transform)
                }
                context.fill(path, with: .color(Brand.textSecondary.opacity(0.18)))
                context.stroke(path, with: .color(Brand.textSecondary.opacity(0.5)), lineWidth: 1)
                if r.width > 34 {
                    context.draw(Text(shape.name)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Brand.textSecondary),
                        in: r.insetBy(dx: 2, dy: 2))
                }
            }

            // Tables.
            for table in result.plan.tables {
                let r = rect(table.positionX, table.positionY, table.width, table.height)
                let isRound = table.shape == "circle" || table.shape == "oval"
                var path = isRound ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: 3)
                if table.rotation != 0 && !isRound {
                    let transform = CGAffineTransform(translationX: r.midX, y: r.midY)
                        .rotated(by: table.rotation * .pi / 180)
                        .translatedBy(x: -r.midX, y: -r.midY)
                    path = path.applying(transform)
                }
                context.fill(path, with: .color(Brand.purple.opacity(0.18)))
                context.stroke(path, with: .color(Brand.purple), lineWidth: 1.5)
                context.draw(Text("\(table.capacity)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Brand.purple),
                    at: CGPoint(x: r.midX, y: r.midY))
            }
        }
        .frame(height: 250)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.separator, lineWidth: 1)
        )
        .accessibilityLabel("Extracted floor plan preview")
    }

    private func detectedCard(_ result: AiFloorplanImportResponse) -> some View {
        let noScale = result.scaleSource == "assumed"
        let lowConfidence = result.confidence < 0.6
        return VStack(alignment: .leading, spacing: 8) {
            Text("DETECTED")
                .scaledFont(size: 11, weight: .semibold)
                .kerning(0.8)
                .foregroundStyle(Brand.textSecondary)
            Text(result.roomName)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(Brand.textPrimary)
            Text(detectedSummary(result, noScale: noScale))
                .scaledFont(size: 13)
                .foregroundStyle(Brand.textSecondary)
            Text(fixtureSummary(result))
                .scaledFont(size: 12)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if result.tallyStatus == "match" {
                Label("Seat totals match the tally written on the plan.",
                      systemImage: "checkmark.circle.fill")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(Brand.successText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if result.tallyStatus == "mismatch", let note = result.tallyNote {
                warningLabel(note)
            }

            if result.crossedOutCount > 0 {
                Text("\(result.crossedOutCount) crossed-out table\(result.crossedOutCount == 1 ? "" : "s") on the plan excluded.")
                    .scaledFont(size: 12)
                    .foregroundStyle(Brand.textSecondary)
            }
            if result.plan.tables.isEmpty {
                warningLabel("No tables detected. You can still import the room and fixtures, or try a clearer, straight-on image.")
            }
            if noScale {
                warningLabel("No scale bar or dimensions on this plan. Tables will be added without a room, and sizes are estimates.")
            } else if lowConfidence {
                warningLabel("The scale is a best guess. Double-check room size before finalizing.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.separator, lineWidth: 1)
        )
    }

    private func warningLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .scaledFont(size: 12, weight: .medium)
            .foregroundStyle(Brand.warningText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detectedSummary(_ result: AiFloorplanImportResponse, noScale: Bool) -> String {
        var parts: [String] = []
        if !noScale {
            parts.append("\(Int(result.roomWidthFt)) × \(Int(result.roomHeightFt)) ft")
        }
        parts.append("\(result.plan.tables.count) tables")
        parts.append("\(result.seatCount) seats")
        return parts.joined(separator: " · ")
    }

    /// Named list of detected fixtures so a missing dance floor or stage is
    /// obvious at a glance, not something discovered after applying.
    private func fixtureSummary(_ result: AiFloorplanImportResponse) -> String {
        let shapes = result.plan.shapes
        guard !shapes.isEmpty else {
            return "No fixtures found (dance floor, stage, bar…). Add any manually after import."
        }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in shapes {
            if counts[s.name] == nil { order.append(s.name) }
            counts[s.name, default: 0] += 1
        }
        let parts = order.map { name -> String in
            let n = counts[name] ?? 1
            return n > 1 ? "\(n)× \(name)" : name
        }
        return "Fixtures: " + parts.joined(separator: ", ")
    }

    // MARK: - Footer CTA

    private var footer: some View {
        Group {
            if step == .review {
                Button(action: apply) {
                    HStack(spacing: 9) {
                        if applying {
                            ProgressView().tint(.white)
                            Text("Adding…")
                        } else {
                            Image(systemName: "checkmark")
                                .scaledFont(size: 17, weight: .bold)
                            Text("Add to My Floor Plan")
                        }
                    }
                }
                .buttonStyle(.primaryBrand)
                .disabled(planIsEmpty || applying)
            } else {
                Button(action: analyze) {
                    HStack(spacing: 9) {
                        if step == .analyzing {
                            ProgressView().tint(.white)
                            Text("Analyzing…")
                        } else {
                            Image(systemName: "wand.and.stars")
                                .scaledFont(size: 17, weight: .bold)
                            Text("Analyze Floor Plan")
                        }
                    }
                }
                .buttonStyle(.primaryBrand)
                .disabled(picked == nil || step == .analyzing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Brand.separator).frame(height: 1), alignment: .top)
    }

    // MARK: - File handling

    private static var allowedTypes: [UTType] {
        [.png, .jpeg, .webP, .pdf, .image]
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "Couldn't load that photo. Try a different one."
            return
        }
        setImage(image, name: "floor-plan.jpg")
    }

    private func handleFileImport(_ outcome: Result<[URL], Error>) {
        switch outcome {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    guard data.count <= Self.maxFileBytes else {
                        errorMessage = "That file is over 10 MB. Try a smaller PDF or a screenshot of the plan."
                        return
                    }
                    errorMessage = nil
                    picked = PickedPlan(data: data, name: url.lastPathComponent,
                                        contentType: "application/pdf", preview: nil)
                } else if let image = UIImage(data: data) {
                    setImage(image, name: url.lastPathComponent)
                } else {
                    errorMessage = "Please choose a PNG, JPEG, or WebP image, or a PDF."
                }
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        case .failure(let error):
            errorMessage = FriendlyError.message(for: error)
        }
    }

    /// Re-encodes any picked raster image as a bounded JPEG so uploads stay
    /// small and the format is always one the function accepts.
    private func setImage(_ image: UIImage, name: String) {
        let bounded = image.scaledDown(to: Self.maxImageDimension)
        guard let jpeg = bounded.jpegData(compressionQuality: 0.85),
              jpeg.count <= Self.maxFileBytes else {
            errorMessage = "That image is too large. Try a smaller photo or a screenshot of the plan."
            return
        }
        errorMessage = nil
        let base = (name as NSString).deletingPathExtension
        picked = PickedPlan(data: jpeg, name: base.isEmpty ? "floor-plan.jpg" : base + ".jpg",
                            contentType: "image/jpeg", preview: bounded)
    }

    // MARK: - Actions

    private func analyze() {
        guard let picked, step != .analyzing else { return }
        errorMessage = nil
        withAnimation { step = .analyzing }
        analyzingPhraseIndex = 0
        analyzingProgress = 4

        // Rotating phrases + asymptotic progress, cancelled when the step changes.
        Task {
            while step == .analyzing {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard step == .analyzing else { break }
                analyzingProgress = min(92, analyzingProgress + (92 - analyzingProgress) * 0.03)
            }
        }
        Task {
            while step == .analyzing {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                guard step == .analyzing else { break }
                analyzingPhraseIndex = (analyzingPhraseIndex + 1) % Self.analyzingPhrases.count
            }
        }

        Task {
            do {
                let response = try await store.aiAnalyzeFloorPlan(fileData: picked.data,
                                                                  filename: picked.name,
                                                                  contentType: picked.contentType)
                result = response
                withAnimation { step = .review }
            } catch {
                withAnimation { step = .upload }
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }

    private func apply() {
        guard let result, !applying, !planIsEmpty else { return }
        applying = true
        Task {
            do {
                try await store.applyImportedFloorPlan(result.plan)
                applying = false
                dismiss()
            } catch {
                applying = false
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }

    private func startOver() {
        result = nil
        errorMessage = nil
        withAnimation { step = .upload }
    }

    private func handleClose() {
        guard step != .analyzing, !applying else { return }
        dismiss()
    }
}

// MARK: - Image downscale helper

private extension UIImage {
    /// Returns the image scaled so its longest side is ≤ `maxDimension`
    /// (unchanged when already within bounds).
    func scaledDown(to maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
