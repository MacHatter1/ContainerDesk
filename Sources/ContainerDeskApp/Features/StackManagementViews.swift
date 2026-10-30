import ContainerDeskCore
import SwiftUI

struct StackEditorRequest: Identifiable {
    let id = UUID()
    var original: ManagedStack? = nil
    var name = ""
    var containerIDs: Set<String> = []
}

struct StackEditorSheet: View {
    let store: AppStore
    let request: StackEditorRequest
    let onSave: (ManagedStack) -> Void
    private let runtimeScope: String
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedIDs: Set<String>
    @State private var query = ""
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    init(store: AppStore, request: StackEditorRequest, onSave: @escaping (ManagedStack) -> Void) {
        self.store = store
        self.request = request
        self.onSave = onSave
        runtimeScope = store.managedStacks.runtimeScope
        _name = State(initialValue: request.name)
        _selectedIDs = State(initialValue: request.containerIDs)
    }

    private var containers: [ResourceSummary] {
        (store.snapshots[.containers]?.items ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var missingIDs: [String] { request.containerIDs.union(selectedIDs).subtracting(containers.map(\.id)).sorted() }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let errorText { InlineNotice(message: errorText, kind: .error) }
                if let error = store.managedStacks.loadError {
                    InlineNotice(message: error, kind: .error)
                    Button("Reload Stack Library") { store.managedStacks.reload() }
                }
                TextField("Stack name", text: $name, prompt: Text("My application"))
                    .accessibilityLabel("Stack name")
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                Text("Choose containers for this stack. Selecting a container from another saved stack moves it here. Removing a member keeps the container running and preserves its data.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Search containers", text: $query).textFieldStyle(.roundedBorder)
                    Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh(.containers, force: true) } }
                        .labelStyle(.iconOnly).help("Refresh available containers")
                }
                if case .failed(let message) = store.snapshots[.containers]?.state {
                    InlineNotice(message: message, kind: .warning)
                }
                List {
                    Section("Available containers") {
                        ForEach(containers.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }) { container in
                            Toggle(isOn: membership(container.id)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(container.title).fontWeight(.medium)
                                    HStack {
                                        Text(container.state ?? "Unknown")
                                        if let owner = store.managedStacks.stacks.first(where: { $0.containerIDs.contains(container.id) }), owner.id != request.original?.id {
                                            Text("In \(owner.name) · moves here when selected")
                                        }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Include \(container.title)")
                            .padding(.vertical, 3)
                        }
                        if containers.isEmpty { Text("No containers available. You can save an empty stack and run a container into it later.").foregroundStyle(.secondary) }
                    }
                    if !missingIDs.isEmpty {
                        Section("Saved references unavailable in this runtime") {
                            ForEach(missingIDs, id: \.self) { id in
                                Toggle(id, isOn: membership(id)).toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .padding(20)
            .navigationTitle(request.original == nil ? "Create Stack" : "Edit Stack")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.original == nil ? "Create Stack" : "Save Changes", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.managedStacks.loadError != nil)
                }
            }
        }
        .frame(width: 620, height: 580)
        .defaultFocus($nameFocused, true)
        .task { await store.refresh(.containers, force: true) }
    }

    private func membership(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedIDs.contains(id) }, set: { selected in
            if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        })
    }

    private func save() {
        do {
            guard store.managedStacks.runtimeScope == runtimeScope else { throw ManagedStackError.runtimeChanged }
            let saved = try store.managedStacks.save(name: name, containerIDs: selectedIDs, replacing: request.original)
            onSave(saved)
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

struct StackManagementActions: View {
    let stack: ManagedStack?
    let disabled: Bool
    let edit: () -> Void
    let run: (ManagedStack) -> Void
    let delete: (ManagedStack) -> Void

    var body: some View {
        HStack(spacing: 7) {
            if let stack {
                Button("Manage Containers…", systemImage: "shippingbox") { edit() }
                Button("Run Container…", systemImage: "plus") { run(stack) }
                Menu {
                    Button("Rename Stack…") { edit() }
                    Divider()
                    Button("Delete Stack…", role: .destructive) { delete(stack) }
                } label: { Image(systemName: "ellipsis.circle") }
                .help("More stack actions")
                .accessibilityLabel("More stack actions")
            } else {
                Button("Save as Editable Stack…", systemImage: "square.and.pencil") { edit() }
            }
        }
        .disabled(disabled)
        .buttonStyle(.bordered)
    }
}

struct StackMemberMenu: View {
    let containerID: String
    let containerTitle: String
    let stack: ManagedStack
    let library: ManagedStacksStore
    let onError: (String) -> Void

    var body: some View {
        Menu {
            Button("Remove from Stack") {
                perform { try library.remove(containerID: containerID, from: stack) }
            }
            let destinations = library.stacks.filter { $0.id != stack.id }
            if !destinations.isEmpty {
                Menu("Move to Stack") {
                    ForEach(destinations) { destination in
                        Button(destination.name) { perform { try library.assign(containerID: containerID, to: destination.id) } }
                    }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Manage \(containerTitle)")
        .accessibilityLabel("Manage \(containerTitle)")
        .disabled(library.loadError != nil)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { onError(error.localizedDescription) }
    }
}
