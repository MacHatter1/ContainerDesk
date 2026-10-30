import ContainerDeskCore
import SwiftUI

struct ContentView: View {
    let store: AppStore
    let mlxStore: MLXStore
    let externalMLXStore: ExternalMLXStore
    @SceneStorage("containerDesk.selectedSection") private var selectedRawValue = ContainerSection.containers.rawValue
    @SceneStorage("containerDesk.sceneID") private var sceneID = UUID().uuidString
    @State private var cleanupCategory: CleanupCategory?
    @State private var navigationPerformance = NavigationPerformanceTracker()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var cleanupNavigation: CleanupNavigationAction {
        CleanupNavigationAction { category in
            let current = ContainerSection(rawValue: selectedRawValue) ?? .containers
            navigationPerformance.begin(from: current, to: .cleanup)
            cleanupCategory = category
            selectedRawValue = ContainerSection.cleanup.rawValue
        }
    }

    private var selection: Binding<ContainerSection?> {
        Binding(
            get: { ContainerSection(rawValue: selectedRawValue) },
            set: {
                let current = ContainerSection(rawValue: selectedRawValue) ?? .containers
                let destination = $0 ?? .containers
                navigationPerformance.begin(from: current, to: destination)
                if destination == .cleanup { cleanupCategory = nil }
                selectedRawValue = destination.rawValue
            }
        )
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

                List(selection: selection) {
                    Section("Resources") {
                        sectionRow(.stacks, icon: "square.stack.3d.up.fill")
                        sectionRow(.containers, icon: "shippingbox")
                        sectionRow(.images, icon: "square.stack.3d.up")
                        sectionRow(.volumes, icon: "externaldrive")
                        sectionRow(.networks, icon: "point.3.connected.trianglepath.dotted")
                        sectionRow(.registries, icon: "externaldrive.badge.person.crop")
                    }
                    Section("Development") {
                        sectionRow(.builds, icon: "hammer")
                        sectionRow(.compose, icon: "square.stack.3d.forward.dottedline")
                        sectionRow(.kubernetes, icon: "circle.hexagongrid")
                        sectionRow(.machines, icon: "desktopcomputer")
                    }
                    Section("Runtime") {
                        sectionRow(.system, icon: "gearshape.2")
                        sectionRow(.cleanup, icon: "sparkles")
                        sectionRow(.activity, icon: "clock.arrow.circlepath")
                    }
                    Section("Local AI") {
                        sectionRow(.mlxModels, icon: "cpu")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

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
            FeatureRootView(section: ContainerSection(rawValue: selectedRawValue) ?? .containers, store: store, mlxStore: mlxStore, externalMLXStore: externalMLXStore, sceneID: sceneID, navigationPerformance: navigationPerformance, cleanupCategory: cleanupCategory)
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
            store.setWindowActive(sceneID, active: phase == .active)
        }
        .onChange(of: selectedRawValue) { _, rawValue in
            store.setVisibleSection(ContainerSection(rawValue: rawValue), for: sceneID)
        }
        .task {
            store.setVisibleSection(ContainerSection(rawValue: selectedRawValue), for: sceneID)
            store.setWindowActive(sceneID, active: true)
        }
        .task {
            await navigationPerformance.runBenchmark { selection.wrappedValue = $0 }
        }
        .onDisappear {
            store.setWindowActive(sceneID, active: false)
            mlxStore.discardChatState(forScene: sceneID)
        }
    }

    private func sectionRow(_ section: ContainerSection, icon: String) -> some View {
        Label {
            Text(section.title)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(selectedRawValue == section.rawValue ? .primary : sidebarTint(section))
        }
        .tag(section)
    }

    private func sidebarTint(_ section: ContainerSection) -> Color {
        switch section {
        case .stacks, .containers, .images, .registries: .accentColor
        case .volumes, .machines: .purple
        case .networks, .compose: .teal
        case .builds, .kubernetes: .orange
        case .cleanup: .mint
        case .mlxModels: .indigo
        case .system, .activity: .secondary
        }
    }
}
