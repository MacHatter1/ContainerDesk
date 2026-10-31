import ContainerDeskCore
import SwiftUI

struct ContentView: View {
    let store: AppStore
    let mlxStore: MLXStore
    let externalMLXStore: ExternalMLXStore
    @SceneStorage("containerDesk.selectedSection") private var selectedRawValue = ContainerSection.containers.rawValue
    @SceneStorage("containerDesk.sceneID") private var sceneID = UUID().uuidString
    @SceneStorage("containerDesk.selectedStackWorkspace") private var selectedStackWorkspaceID = ""
    @State private var cleanupCategory: CleanupCategory?
    @State private var navigationPerformance = NavigationPerformanceTracker()
    @State private var resourceStates = ResourceFeatureStateCache()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var cleanupNavigation: CleanupNavigationAction {
        CleanupNavigationAction { category in
            navigate(to: .cleanup, category: category)
        }
    }

    private var selection: Binding<ContainerSection?> {
        Binding(
            get: { ContainerSection(rawValue: selectedRawValue) },
            set: { navigate(to: $0 ?? .containers) }
        )
    }

    private func navigate(to destination: ContainerSection, category: CleanupCategory? = nil) {
        let current = ContainerSection(rawValue: selectedRawValue) ?? .containers
        navigationPerformance.begin(from: current, to: destination)
        if destination == .cleanup { cleanupCategory = category }
        selectedRawValue = destination.rawValue
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 38, height: 38)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ContainerDesk")
                            .font(.headline)
                        Text("Local workspace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)

                ContainerSidebarList(selection: selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(store.runtimeIsConnected ? .green : .secondary)
                            .frame(width: 7, height: 7)
                        Text(store.runtimeConnectionLabel)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(store.runtimeVersionLabel ?? "Apple container —")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                else { Rectangle().fill(.regularMaterial) }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 280)
        } detail: {
            FeatureRootView(section: ContainerSection(rawValue: selectedRawValue) ?? .containers, store: store, mlxStore: mlxStore, externalMLXStore: externalMLXStore, sceneID: sceneID, navigationPerformance: navigationPerformance, resourceStates: resourceStates, selectedWorkspaceID: $selectedStackWorkspaceID, cleanupCategory: cleanupCategory)
        }
        .environment(\.openCleanup, cleanupNavigation)
        .focusedSceneValue(\.cleanupNavigation, cleanupNavigation)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 680)
        .overlay(alignment: .bottom) {
            if let message = mlxStore.shutdownMessage {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background {
                    if reduceTransparency { Color(nsColor: .controlBackgroundColor) }
                    else { Rectangle().fill(.regularMaterial) }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: mlxStore.shutdownMessage != nil)
        .onChange(of: scenePhase) { _, phase in
            // Keep history and exit alerts useful while another app has keyboard focus.
            store.setWindowActive(sceneID, active: phase != .background)
        }
        .onChange(of: selectedRawValue) { _, rawValue in
            store.setVisibleSection(ContainerSection(rawValue: rawValue), for: sceneID)
        }
        .onChange(of: store.limitsOperationContainerID) { _, target in
            if target != nil { resourceStates.terminateTerminalSessions() }
        }
        .task {
            store.setVisibleSection(ContainerSection(rawValue: selectedRawValue), for: sceneID)
            store.setWindowActive(sceneID, active: true)
        }
        .task {
            await navigationPerformance.runBenchmark(prepare: prepareNavigationBenchmark) { selection.wrappedValue = $0 }
        }
        .onDisappear {
            store.setWindowActive(sceneID, active: false)
            mlxStore.discardChatState(forScene: sceneID)
            resourceStates.terminateTerminalSessions()
        }
    }

    private func prepareNavigationBenchmark() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--navigation-benchmark-stack=largest") else { return }
        for section: ContainerSection in [.containers, .images, .volumes, .networks] {
            await store.refresh(section, force: true)
        }
        guard let largest = store.stackWorkspaces.max(by: { $0.containers.count < $1.containers.count }),
              !largest.containers.isEmpty else {
            throw FeatureCommandError(message: "The large-stack benchmark requires loaded container data.")
        }
        selectedStackWorkspaceID = largest.id
    }
}
