import SwiftUI

struct ContentView: View {
    @StateObject private var actrService = ActrService()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // Status
                HStack {
                    Circle()
                        .fill(actrService.isReady ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(actrService.status)
                        .font(.footnote)
                        .foregroundStyle(actrService.isReady ? .green : .secondary)
                }

                // Discovery button
                Button {
                    Task { await actrService.runAllProbes() }
                } label: {
                    HStack {
                        if actrService.isRunning {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(actrService.isRunning ? "Discovering..." : "Discover Target")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!actrService.isReady || actrService.isRunning)

                // Probe results
                if !actrService.results.isEmpty {
                    List(actrService.results) { result in
                        HStack {
                            Image(systemName: result.icon)
                                .foregroundStyle(result.passed ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.body)
                                Text(result.details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(result.durationMs)ms")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 260)
                }

                // Log output
                if !actrService.logLines.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(actrService.logLines.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(line.contains("[PASS]") ? .green : line.contains("[FAIL]") ? .red : .primary)
                                        .id(idx)
                                }
                            }
                        }
                        .onChange(of: actrService.logLines.count) { _, newCount in
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                    .padding(8)
                    .background(Color(.systemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Spacer()
            }
            .padding()
            .navigationTitle("DataStreamApp")
        }
        .task {
            await actrService.startIfNeeded()
            NSLog("[DataStreamApp] startIfNeeded returned, shouldAutoRun=\(actrService.shouldAutoRun), isReady=\(actrService.isReady)")
            if actrService.shouldAutoRun {
                // Wait until ACTR node is ready, then check target discovery.
                while !actrService.isReady {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await actrService.runAllProbes()
            }
        }
    }
}
