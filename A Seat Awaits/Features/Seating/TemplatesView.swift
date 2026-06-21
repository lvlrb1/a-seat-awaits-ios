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
    @Environment(\.dismiss) private var dismiss

    @State private var showingSavePrompt = false
    @State private var newName = ""
    /// The template the user is about to apply (drives the replace confirmation).
    @State private var pendingApply: FloorPlanTemplate?
    /// The template being overwritten by the current save, if any.
    @State private var overwriteTarget: FloorPlanTemplate?
    @State private var isWorking = false

    private var hasLayout: Bool { !store.tables.isEmpty || !store.rooms.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    saveCard
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
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.accent)
                }
            }
            .task { await store.fetchTemplates() }
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
            Button("Replace layout", role: .destructive) {
                if let template = pendingApply { Task { await apply(template) } }
                pendingApply = nil
            }
            Button("Cancel", role: .cancel) { pendingApply = nil }
        } message: {
            Text("This replaces every table and room in this event with the template's layout. Decorative shapes are kept; seated guests become unassigned.")
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
                .font(.system(size: 12, weight: .bold))
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
            .opacity(hasLayout ? 1 : 0.5)

            if !hasLayout {
                Text("Add a table or room first, then save it as a template.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
            }
        }
    }

    // MARK: - Saved templates

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR TEMPLATES")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Brand.textSecondary)

            if store.templates.isEmpty {
                Text("No saved templates yet.")
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .brandCard()
            } else {
                VStack(spacing: 10) {
                    ForEach(store.templates) { template in
                        templateRow(template)
                    }
                }
            }
        }
    }

    private func templateRow(_ template: FloorPlanTemplate) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.plumChipFill)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Brand.plum)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Text(subtitle(template))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Button { pendingApply = template } label: {
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
                    Task { await store.deleteTemplate(template) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Brand.accent)
            }

            Button("Apply") { pendingApply = template }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Brand.accent)
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
