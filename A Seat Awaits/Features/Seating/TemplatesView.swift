//
//  TemplatesView.swift
//  A Seat Awaits
//
//  Save the current floor-plan layout (tables + rooms) as a reusable, per-user
//  template, and apply / overwrite / delete saved templates. Applying a template
//  REPLACES the event's tables and rooms (decorative shapes are kept), matching
//  the web app. Editor-only — reached from the canvas Add menu.
//

import SwiftUI

struct TemplatesView: View {
    @Bindable var store: SeatingStore
    /// Opens the save-name prompt as soon as the sheet appears — the "Save as
    /// Template" entry points use this so saving is one tap, not a hunt.
    var promptSaveOnAppear = false
    @Environment(\.dismiss) private var dismiss

    @State private var showingSavePrompt = false
    @State private var newName = ""
    /// The template the user is about to apply (drives the replace confirmation).
    @State private var pendingApply: FloorPlanTemplate?
    /// The template being overwritten by the current save, if any.
    @State private var overwriteTarget: FloorPlanTemplate?
    /// The saved template the user is about to delete (drives the confirmation).
    @State private var pendingDelete: FloorPlanTemplate?
    @State private var isWorking = false
    /// True until the first fetch of saved templates completes, so the empty
    /// state never flashes before the list arrives.
    @State private var isLoadingTemplates = true

    private var hasLayout: Bool { !store.tables.isEmpty || !store.rooms.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    saveCard
                    starterSection
                    savedSection
                }
                .padding(20)
            }
            .background(Brand.canvas)
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .scaledFont(size: 16, weight: .bold)
                        .foregroundStyle(Brand.accent)
                }
            }
            .task {
                await store.fetchTemplates()
                isLoadingTemplates = false
            }
            .task {
                guard promptSaveOnAppear, hasLayout else { return }
                // Let the sheet's presentation animation settle before
                // stacking the alert on top of it.
                try? await Task.sleep(for: .milliseconds(450))
                showingSavePrompt = true
            }
            .overlay { if isWorking { workingOverlay } }
        }
        .alert(overwriteTarget == nil ? "Save template" : "Overwrite template",
               isPresented: $showingSavePrompt) {
            TextField("Template name", text: $newName)
            Button("Cancel", role: .cancel) { overwriteTarget = nil }
            Button("Save") { Task { await save() } }
        } message: {
            Text(saveMessage)
        }
        .confirmationDialog("Apply \(pendingApply?.name ?? "template")?",
                            isPresented: Binding(get: { pendingApply != nil },
                                                 set: { if !$0 { pendingApply = nil } }),
                            titleVisibility: .visible) {
            Button("Replace Layout", role: .destructive) {
                if let template = pendingApply { Task { await apply(template) } }
                pendingApply = nil
            }
            Button("Cancel", role: .cancel) { pendingApply = nil }
        } message: {
            Text("This replaces every table and room in this event with the template's layout. Decorative shapes are kept; seated guests become unassigned. You can undo for a few seconds.")
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "template")”?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Template", role: .destructive) {
                if let template = pendingDelete { Task { await store.deleteTemplate(template) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the template from every event. Layouts you already applied stay as they are.")
        }
    }

    /// Applying onto an empty event has nothing to replace, so skip the
    /// "replace layout?" question and just do it.
    private func requestApply(_ template: FloorPlanTemplate) {
        if hasLayout {
            pendingApply = template
        } else {
            Task { await apply(template) }
        }
    }

    private var saveMessage: String {
        if let overwriteTarget {
            return "Replace “\(overwriteTarget.name)” with this event's current \(layoutSummary)."
        }
        return "Save this event's current \(layoutSummary) to reuse on any event."
    }

    private var layoutSummary: String {
        let t = store.tables.count
        let r = store.rooms.count
        let tables = "\(t) table\(t == 1 ? "" : "s")"
        return r > 0 ? "\(tables) and \(r) room\(r == 1 ? "" : "s")" : tables
    }

    // MARK: - Save current layout

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THIS EVENT")
                .scaledFont(size: 12, weight: .bold)
                .tracking(0.6)
                .foregroundStyle(Brand.textSecondary)

            Button {
                overwriteTarget = nil
                newName = ""
                showingSavePrompt = true
            } label: {
                Label("Save current layout as template", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.secondaryOutline)
            .disabled(!hasLayout)

            if !hasLayout {
                Text("Add a table or room first, then save it as a template.")
                    .scaledFont(size: 13)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
    }

    // MARK: - Starter layouts (built in, local only)

    /// Five bundled layouts so a brand-new planner has somewhere to start.
    /// They apply through the same path as saved templates (undo included)
    /// and never touch the server's template table.
    private var starterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STARTER LAYOUTS")
                .scaledFont(size: 12, weight: .bold)
                .tracking(0.6)
                .foregroundStyle(Brand.textSecondary)

            VStack(spacing: 10) {
                ForEach(StarterLayout.all) { starter in
                    starterRow(starter)
                }
            }
        }
    }

    private func starterRow(_ starter: StarterLayout) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.plumChipFill)
                Image(systemName: starter.systemImage)
                    .scaledFont(size: 17, weight: .bold)
                    .foregroundStyle(Brand.plum)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(starter.template.name)
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Text(starter.blurb)
                    .scaledFont(size: 13)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(2)
                Text(subtitle(starter.template))
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Apply") { requestApply(starter.template) }
                .scaledFont(size: 14, weight: .bold)
                .foregroundStyle(Brand.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Apply \(starter.template.name)")
        }
        .padding(14)
        .brandCard()
    }

    // MARK: - Saved templates

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR TEMPLATES")
                .scaledFont(size: 12, weight: .bold)
                .tracking(0.6)
                .foregroundStyle(Brand.textSecondary)

            if isLoadingTemplates && store.templates.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Brand.accent)
                    Text("Loading your templates…")
                        .scaledFont(size: 15)
                        .foregroundStyle(Brand.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .brandCard()
            } else if store.templates.isEmpty {
                savedEmptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(store.templates) { template in
                        templateRow(template)
                    }
                }
            }
        }
    }

    private var savedEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.square")
                .scaledFont(size: 30, weight: .semibold)
                .foregroundStyle(Brand.accent)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text("No Saved Templates")
                .scaledFont(size: 16, weight: .bold)
                .foregroundStyle(Brand.textPrimary)
            Text("Save a floor plan you like and reuse it on any event.")
                .scaledFont(size: 14)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .brandCard()
    }

    private func templateRow(_ template: FloorPlanTemplate) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.plumChipFill)
                Image(systemName: "square.grid.2x2")
                    .scaledFont(size: 17, weight: .bold)
                    .foregroundStyle(Brand.plum)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Text(subtitle(template))
                    .scaledFont(size: 13)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Button { requestApply(template) } label: {
                    Label("Apply to this event", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    overwriteTarget = template
                    newName = template.name
                    showingSavePrompt = true
                } label: {
                    Label("Overwrite with current layout", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!hasLayout)
                Divider()
                Button(role: .destructive) {
                    pendingDelete = template
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .scaledFont(size: 22)
                    .foregroundStyle(Brand.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Template options")

            Button("Apply") { requestApply(template) }
                .scaledFont(size: 14, weight: .bold)
                .foregroundStyle(Brand.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Apply \(template.name)")
        }
        .padding(14)
        .brandCard()
    }

    private func subtitle(_ template: FloorPlanTemplate) -> String {
        let seats = template.totalSeats
        guard seats > 0 else { return template.summary }
        return "\(template.summary) · \(seats) seats"
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            ProgressView().controlSize(.large).tint(Brand.accent)
                .padding(24)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Actions

    private func save() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { overwriteTarget = nil; return }
        isWorking = true
        await store.saveTemplate(name: name, overwriteId: overwriteTarget?.id)
        isWorking = false
        overwriteTarget = nil
        newName = ""
    }

    private func apply(_ template: FloorPlanTemplate) async {
        isWorking = true
        await store.applyTemplate(template)
        isWorking = false
        dismiss()
    }
}
