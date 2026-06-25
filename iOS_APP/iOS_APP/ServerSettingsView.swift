import SwiftUI
import UIKit

enum ServerMode: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: Self { self }
    var title: String { self == .local ? "本地读取" : "远端服务器" }
}

struct RemoteServerEndpoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var publicKey: String?

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名服务器" : name
    }

    var hasPublicKey: Bool {
        publicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

enum RemoteServerStore {
    static func load(from encoded: String) -> [RemoteServerEndpoint] {
        guard let data = encoded.data(using: .utf8),
              let servers = try? JSONDecoder().decode([RemoteServerEndpoint].self, from: data)
        else { return [] }
        return servers
    }

    static func save(_ servers: [RemoteServerEndpoint]) -> String {
        guard let data = try? JSONEncoder().encode(servers),
              let encoded = String(data: data, encoding: .utf8)
        else { return "" }
        return encoded
    }
}

struct ServerSettingsView: View {
    enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Binding var mode: ServerMode
    @Binding var selectedRemoteURL: String
    @Binding var remoteServersData: String
    @AppStorage("privacyMode") private var privacyMode = false
    @State private var testState: TestState = .idle
    @State private var isAddingServer = false
    @State private var newServerName = ""
    @State private var newServerURL = ""
    @State private var newServerPublicKey = ""
    @State private var addServerError: String?

    private var endpoint: String {
        selectedRemoteURL
    }

    private var servers: [RemoteServerEndpoint] {
        RemoteServerStore.load(from: remoteServersData)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("模式") {
                    Picker("模式", selection: $mode) {
                        ForEach(ServerMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .local {
                        Text("如需实现其他功能需要配置对应远端服务器")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("选择一个由您自行添加配置的服务器")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if mode == .remote {
                    Section("服务器列表") {
                        if servers.isEmpty {
                            Text("暂无服务器，先添加一个远端地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(servers) { server in
                            Button {
                                selectedRemoteURL = server.url
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(server.displayName)
                                            .foregroundStyle(.primary)
                                        Text(server.url)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Label(
                                            server.hasPublicKey ? "RSA 公钥已配置" : "缺少 RSA 公钥",
                                            systemImage: server.hasPublicKey ? "lock.fill" : "exclamationmark.triangle"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(server.hasPublicKey ? .green : .orange)
                                    }
                                    Spacer()
                                    if selectedRemoteURL == server.url {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                        .onDelete(perform: deleteServers)

                        Button {
                            isAddingServer.toggle()
                            addServerError = nil
                        } label: {
                            Label(isAddingServer ? "收起" : "添加服务器", systemImage: isAddingServer ? "chevron.up" : "plus")
                        }

                        if isAddingServer {
                            TextField("服务器名称", text: $newServerName)
                            TextField("https://你的域名/路径", text: $newServerURL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("RSA 公钥")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $newServerPublicKey)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minHeight: 120)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(.separator).opacity(0.35))
                                    )
                                Text("支持 PEM 或 X.509 DER Base64\n远端提交时只上传 RSA 加密后的卡片安全数据")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button("保存服务器", action: addServer)
                            if let addServerError {
                                Text(addServerError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Section {
                        Button(action: startConnectionTest) {
                            HStack {
                                Text("测试服务器连接")
                                Spacer()
                                testIndicator
                            }
                        }
                        .disabled(testState == .testing || selectedRemoteURL.isEmpty)

                        if case .failure(let message) = testState {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } footer: {
                        Text("服务器地址只保存在本机")
                    }
                }

                Section("显示") {
                    Toggle(isOn: $privacyMode) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("隐私显示")
                                Text("默认只显示 IDM 和访问码最后 4 位")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "shield.lefthalf.filled")
                        }
                    }
                }
            }
            .navigationTitle("服务器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var testIndicator: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func startConnectionTest() {
        selectedRemoteURL = CardAPI.normalizedEndpoint(selectedRemoteURL)
        testState = .testing
        Task {
            do {
                try await CardAPI.testConnection(to: endpoint)
                testState = .success
            } catch is CancellationError {
                testState = .idle
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func addServer() {
        let normalizedURL = CardAPI.normalizedEndpoint(newServerURL)
        do {
            _ = try CardAPI.validatedEndpoint(normalizedURL)
            try Spad0RSA.validatePublicKey(newServerPublicKey)
        } catch {
            addServerError = error.localizedDescription
            return
        }

        let name = newServerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = newServerPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = servers
        if let index = updated.firstIndex(where: { $0.url == normalizedURL }) {
            updated[index].name = name.isEmpty ? updated[index].name : name
            updated[index].publicKey = publicKey
        } else {
            updated.append(RemoteServerEndpoint(name: name, url: normalizedURL, publicKey: publicKey))
        }
        remoteServersData = RemoteServerStore.save(updated)
        selectedRemoteURL = normalizedURL
        mode = .remote
        newServerName = ""
        newServerURL = ""
        newServerPublicKey = ""
        addServerError = nil
        isAddingServer = false
    }

    private func deleteServers(at offsets: IndexSet) {
        var updated = servers
        updated.remove(atOffsets: offsets)
        remoteServersData = RemoteServerStore.save(updated)
        if !updated.contains(where: { $0.url == selectedRemoteURL }) {
            selectedRemoteURL = updated.first?.url ?? ""
        }
    }

}
