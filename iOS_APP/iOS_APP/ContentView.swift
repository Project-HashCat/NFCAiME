import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @AppStorage("serverMode") private var serverMode: ServerMode = .local
    @AppStorage("selectedRemoteServerURL") private var selectedRemoteServerURL = ""
    @AppStorage("remoteServers") private var remoteServersData = ""
    @AppStorage("privacyMode") private var privacyMode = false
    @StateObject private var reader: CardReader
    @State private var selectedSection: AppSection = .scan
    @State private var showsMenu = false
    @State private var showsSettings = false
    @State private var savedCards: [SavedAimeCard] = SavedAimeCardStore.load()
    @State private var selectedCardID: UUID?
    @State private var editingCard: SavedAimeCard?

    private var remoteServers: [RemoteServerEndpoint] {
        RemoteServerStore.load(from: remoteServersData)
    }

    private var selectedRemoteServer: RemoteServerEndpoint? {
        remoteServers.first { $0.url == selectedRemoteServerURL }
    }

    private var endpoint: String {
        serverMode == .remote ? (selectedRemoteServer?.url ?? "") : ""
    }

    private var selectedCard: SavedAimeCard? {
        guard let selectedCardID else { return savedCards.first }
        return savedCards.first { $0.id == selectedCardID } ?? savedCards.first
    }

    init() {
        _reader = StateObject(wrappedValue: CardReader())
    }

    init(reader: CardReader) {
        _reader = StateObject(wrappedValue: reader)
        _savedCards = State(initialValue: [])
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .leading) {
                AppBackground()
                currentSection
                    .disabled(showsMenu)
                    .blur(radius: showsMenu ? 2 : 0)

                if showsMenu {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { showsMenu = false }
                    SideMenu(
                        selectedSection: selectedSection,
                        onSelect: { section in
                            selectedSection = section
                            showsMenu = false
                        },
                        onClose: { showsMenu = false }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: showsMenu)
            .navigationTitle(showsMenu ? "" : selectedSection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !showsMenu {
                        Button {
                            showsMenu = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                        .accessibilityLabel("打开侧边栏")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedSection == .scan {
                        Button {
                            showsSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("服务器设置")
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                ServerSettingsView(
                    mode: $serverMode,
                    selectedRemoteURL: $selectedRemoteServerURL,
                    remoteServersData: $remoteServersData
                )
            }
            .sheet(item: $editingCard) { card in
                EditCardView(card: card) { updated in
                    upsert(updated)
                } onDelete: {
                    delete(card)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var currentSection: some View {
        switch selectedSection {
        case .cards:
            SavedCardsView(
                cards: savedCards,
                selectedCard: selectedCard,
                onSelect: { selectedCardID = $0.id },
                onEdit: { editingCard = $0 },
                onDelete: delete,
                privacyMode: privacyMode,
                onScan: { selectedSection = .scan }
            )
        case .scan:
            ScanPage(
                reader: reader,
                serverMode: serverMode,
                selectedServer: selectedRemoteServer,
                privacyMode: privacyMode,
                isLatestSaved: isLatestSaved,
                onScan: {
                    reader.scan(
                        mode: serverMode,
                        serverURL: endpoint,
                        serverPublicKey: selectedRemoteServer?.publicKey
                    )
                },
                onSave: saveLatest
            )
        case .about:
            AboutView(
                debugLogEndpoint: selectedRemoteServer?.url,
                selectedServerName: selectedRemoteServer?.displayName
            )
        }
    }

    private var isLatestSaved: Bool {
        guard let latest = reader.history.first,
              let card = SavedAimeCard(record: latest)
        else { return false }
        return savedCards.contains { $0.identityKey == card.identityKey }
    }

    private func saveLatest() {
        guard let latest = reader.history.first,
              var card = SavedAimeCard(record: latest)
        else { return }
        if let existing = savedCards.first(where: { $0.identityKey == card.identityKey }) {
            card.id = existing.id
            card.label = existing.label
        }
        upsert(card)
        selectedCardID = card.id
        selectedSection = .cards
    }

    private func upsert(_ card: SavedAimeCard) {
        if let index = savedCards.firstIndex(where: { $0.id == card.id || $0.identityKey == card.identityKey }) {
            savedCards[index] = card
        } else {
            savedCards.insert(card, at: 0)
        }
        selectedCardID = card.id
        SavedAimeCardStore.save(savedCards)
    }

    private func delete(_ card: SavedAimeCard) {
        savedCards.removeAll { $0.id == card.id }
        if selectedCardID == card.id {
            selectedCardID = savedCards.first?.id
        }
        SavedAimeCardStore.save(savedCards)
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case scan
    case cards
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .cards: return "我的卡"
        case .scan: return "刷卡"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .cards: return "creditcard"
        case .scan: return "dot.radiowaves.left.and.right"
        case .about: return "info.circle"
        }
    }
}

struct SavedAimeCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    let createdAt: Date
    let updatedAt: Date
    let cardNumber: String?
    let idm: String
    let ckv: String
    let wcnt: String
    let maca: String
    let accessCode: String
    let spad0AccessCode: String?
    let konamiCardNumber: String?
    let privateNetworkNumber: String?

    init?(record: CardReader.ScanRecord) {
        guard record.error == nil,
              let accessCode = record.compactAccessCode,
              !accessCode.isEmpty
        else { return nil }
        let now = Date()
        label = "AiMe 卡"
        createdAt = now
        updatedAt = now
        cardNumber = record.code
        idm = record.idm
        ckv = record.ckv
        wcnt = record.wcnt
        maca = record.maca
        self.accessCode = accessCode.uppercased()
        spad0AccessCode = record.compactSpad0AccessCode?.uppercased()
        konamiCardNumber = record.konamiCardNumber
        privateNetworkNumber = record.privateNetworkNumber
    }

    var identityKey: String {
        idm.replacingOccurrences(of: ":", with: "").lowercased()
    }

    var displayAccessCode: String {
        Self.group(accessCode)
    }

    var displaySpad0AccessCode: String? {
        spad0AccessCode.map(Self.group)
    }

    var displayKonamiCardNumber: String? {
        konamiCardNumber.map(Self.group)
    }

    var displayPrivateNetworkNumber: String? {
        privateNetworkNumber.map(Self.group)
    }

    var displayCardNumber: String {
        cardNumber ?? "未生成 #CARD"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case createdAt
        case updatedAt
        case cardNumber
        case code
        case idm
        case ckv
        case wcnt
        case maca
        case accessCode
        case spad0AccessCode
        case konamiCardNumber
        case privateNetworkNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        cardNumber = try container.decodeIfPresent(String.self, forKey: .cardNumber)
            ?? container.decodeIfPresent(String.self, forKey: .code)
        idm = try container.decode(String.self, forKey: .idm)
        ckv = try container.decode(String.self, forKey: .ckv)
        wcnt = try container.decode(String.self, forKey: .wcnt)
        maca = try container.decode(String.self, forKey: .maca)
        accessCode = try container.decode(String.self, forKey: .accessCode)
        spad0AccessCode = try container.decodeIfPresent(String.self, forKey: .spad0AccessCode)
        konamiCardNumber = try container.decodeIfPresent(String.self, forKey: .konamiCardNumber)
        privateNetworkNumber = try container.decodeIfPresent(String.self, forKey: .privateNetworkNumber)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(cardNumber, forKey: .cardNumber)
        try container.encode(idm, forKey: .idm)
        try container.encode(ckv, forKey: .ckv)
        try container.encode(wcnt, forKey: .wcnt)
        try container.encode(maca, forKey: .maca)
        try container.encode(accessCode, forKey: .accessCode)
        try container.encodeIfPresent(spad0AccessCode, forKey: .spad0AccessCode)
        try container.encodeIfPresent(konamiCardNumber, forKey: .konamiCardNumber)
        try container.encodeIfPresent(privateNetworkNumber, forKey: .privateNetworkNumber)
    }

    private static func group(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(4, value.count - offset))
            return String(value[start..<end])
        }
        .joined(separator: " ")
    }
}

private enum SavedAimeCardStore {
    private static let key = "savedAimeCards"

    static func load() -> [SavedAimeCard] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cards = try? JSONDecoder().decode([SavedAimeCard].self, from: data)
        else { return [] }
        return cards
    }

    static func save(_ cards: [SavedAimeCard]) {
        guard !cards.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private struct AppBackground: View {
    var body: some View {
        Color(.systemGroupedBackground).ignoresSafeArea()
    }
}

private struct SideMenu: View {
    let selectedSection: AppSection
    let onSelect: (AppSection) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onClose) {
                Image(systemName: "line.3.horizontal")
                    .font(.headline.weight(.semibold))
                    .frame(width: 50, height: 38)
                    .foregroundStyle(.primary)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("关闭侧边栏")
            .padding(.bottom, 8)

            ForEach(AppSection.allCases) { section in
                Button {
                    onSelect(section)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: section.symbol)
                            .font(.title3)
                            .frame(width: 32)
                        Text(section.title)
                            .font(.headline)
                        Spacer()
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(section == selectedSection ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(section == selectedSection ? Color.accentColor.opacity(0.55) : Color(.separator).opacity(0.35))
                    )
                }
            }
            Spacer()
        }
        .padding(.top, 64)
        .padding(.horizontal, 14)
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .foregroundStyle(.primary)
        .ignoresSafeArea()
    }
}

private struct ScanPage: View {
    @ObservedObject var reader: CardReader
    let serverMode: ServerMode
    let selectedServer: RemoteServerEndpoint?
    let privacyMode: Bool
    let isLatestSaved: Bool
    let onScan: () -> Void
    let onSave: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ReaderHeader(phase: reader.phase)
                ScanModeCard(mode: serverMode, selectedServer: selectedServer)
                ScanButton(phase: reader.phase, action: onScan)
                StatusBanner(phase: reader.phase)

                if let latest = reader.history.first {
                    ScanResultCard(
                        record: latest,
                        privacyMode: privacyMode,
                        isSaved: isLatestSaved,
                        onSave: latest.error == nil ? onSave : nil
                    )
                }

                let earlierRecords = Array(reader.history.dropFirst().prefix(5))
                if !earlierRecords.isEmpty {
                    ScanHistorySection(records: earlierRecords, onClear: reader.clearHistory)
                }

            }
            .padding(20)
        }
        .foregroundStyle(.primary)
    }
}

private struct ScanModeCard: View {
    let mode: ServerMode
    let selectedServer: RemoteServerEndpoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: mode == .local ? "iphone.gen3" : "server.rack")
                    .foregroundStyle(mode == .local ? .cyan : .indigo)
                Text(mode.title)
                    .font(.headline)
                Spacer()
                Text(mode == .local ? "离线" : "RSA")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((mode == .local ? Color.cyan : Color.indigo).opacity(0.14), in: Capsule())
                    .foregroundStyle(mode == .local ? .cyan : .indigo)
            }

            if mode == .local {
                Text("点击下方读取你的卡片信息内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let selectedServer {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedServer.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(selectedServer.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(
                        selectedServer.hasPublicKey ? "卡片数据将使用该服务器Key加密上传" : "缺少服务器 RSA 公钥，无法远端刷卡",
                        systemImage: selectedServer.hasPublicKey ? "lock.fill" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(selectedServer.hasPublicKey ? .green : .orange)
                }
            } else {
                Text("还没有选择远端服务器；请在右上角设置里添加服务器地址和 RSA 公钥")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(.separator).opacity(0.25)))
    }
}

private struct SavedCardsView: View {
    let cards: [SavedAimeCard]
    let selectedCard: SavedAimeCard?
    let onSelect: (SavedAimeCard) -> Void
    let onEdit: (SavedAimeCard) -> Void
    let onDelete: (SavedAimeCard) -> Void
    let privacyMode: Bool
    let onScan: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if cards.isEmpty {
                    EmptyCardsView(onScan: onScan)
                } else if cards.count == 1, let card = cards.first {
                    AimeCardFace(label: card.label)
                        .frame(width: 300)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onTapGesture { onSelect(card) }
                        .contextMenu {
                            Button("编辑卡名称", systemImage: "pencil") { onEdit(card) }
                            Button("删除卡", systemImage: "trash", role: .destructive) { onDelete(card) }
                        }

                    if let selectedCard {
                        SavedCardDetail(
                            card: selectedCard,
                            privacyMode: privacyMode,
                            onEdit: { onEdit(selectedCard) }
                        )
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(cards) { card in
                                AimeCardFace(label: card.label)
                                    .frame(width: 300)
                                    .scaleEffect(card.id == selectedCard?.id ? 1 : 0.94)
                                    .opacity(card.id == selectedCard?.id ? 1 : 0.74)
                                    .onTapGesture { onSelect(card) }
                                    .contextMenu {
                                        Button("编辑卡名称", systemImage: "pencil") { onEdit(card) }
                                        Button("删除卡", systemImage: "trash", role: .destructive) { onDelete(card) }
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.horizontal, -20)

                    if let selectedCard {
                        SavedCardDetail(
                            card: selectedCard,
                            privacyMode: privacyMode,
                            onEdit: { onEdit(selectedCard) }
                        )
                    }
                }
            }
            .padding(20)
        }
        .foregroundStyle(.primary)
    }
}

private struct EmptyCardsView: View {
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AimeCardFace(label: nil)
                .frame(maxWidth: 330)
            Text("还没有保存的卡")
                .font(.title3.bold())
            Text("刷卡成功后保存记录，就可以在这里随时查看 Access Code 和 NFC 信息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onScan) {
                Label("去刷卡", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
    }
}

private struct AimeCardFace: View {
    let label: String?

    var body: some View {
        Image("AimeCard")
            .resizable()
            .aspectRatio(945.0 / 592.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topTrailing) {
                if let label, !label.isEmpty {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.46), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(12)
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }
}

private struct SavedCardDetail: View {
    let card: SavedAimeCard
    let privacyMode: Bool
    let onEdit: () -> Void
    @State private var copiedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Issued by")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("SEGA")
                        .font(.title3)
                }
                Spacer()
                Text("Amusement IC")
                    .font(.headline)
                    .foregroundStyle(.black.opacity(0.76))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.green, in: Capsule())
                    .shadow(color: .green.opacity(0.45), radius: 12)
            }

            CardValueRow(
                label: "IDM",
                value: card.idm,
                privacyMode: privacyMode,
                copied: copiedField == "idm",
                onCopy: { copy(card.idm, field: "idm") }
            )
            CardValueRow(
                label: "Access Code",
                value: card.displayAccessCode,
                privacyMode: privacyMode,
                copied: copiedField == "accessCode",
                onCopy: { copy(card.accessCode, field: "accessCode") }
            )
            if let privateNetworkNumber = card.privateNetworkNumber,
               let displayPrivateNetworkNumber = card.displayPrivateNetworkNumber {
                CardValueRow(
                    label: "Private Network",
                    value: displayPrivateNetworkNumber,
                    privacyMode: privacyMode,
                    copied: copiedField == "privateNetworkNumber",
                    onCopy: { copy(privateNetworkNumber, field: "privateNetworkNumber") }
                )
            }
            if let konamiCardNumber = card.konamiCardNumber,
               let displayKonamiCardNumber = card.displayKonamiCardNumber {
                CardValueRow(
                    label: "Konami Card Number",
                    value: displayKonamiCardNumber,
                    privacyMode: privacyMode,
                    copied: copiedField == "konamiCardNumber",
                    onCopy: { copy(konamiCardNumber, field: "konamiCardNumber") }
                )
            }

            Text("卡类型：FeliCa Lite-S")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onEdit) {
                Label("编辑卡片", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(.separator).opacity(0.35)))
    }

    private func copy(_ value: String, field: String) {
        UIPasteboard.general.string = value
        copiedField = field
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedField == field {
                copiedField = nil
            }
        }
    }
}

private struct CardValueRow: View {
    let label: String
    let value: String
    let privacyMode: Bool
    let copied: Bool
    let onCopy: () -> Void
    @State private var isRevealed = false

    private var displayValue: String {
        privacyMode && !isRevealed ? PrivacyMask.lastFour(value) : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: privacyMode && !isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                Text(displayValue)
                    .font(.system(.title3, design: .monospaced))
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator).opacity(0.35)))
        }
    }
}

private struct DetailLine: View {
    let label: String
    let value: String
    var privacyMode = false

    private var displayValue: String {
        privacyMode ? PrivacyMask.lastFour(value) : value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(displayValue)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum PrivacyMask {
    static func lastFour(_ value: String) -> String {
        let visibleCount = 4
        let characters = Array(value)
        var remainingVisible = min(visibleCount, characters.filter { $0.isLetter || $0.isNumber }.count)
        var output: [Character] = []

        for character in characters.reversed() {
            if !(character.isLetter || character.isNumber) {
                output.append(character)
            } else if remainingVisible > 0 {
                output.append(character)
                remainingVisible -= 1
            } else {
                output.append("•")
            }
        }
        return String(output.reversed())
    }
}

private struct EditCardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SavedAimeCard
    let onSave: (SavedAimeCard) -> Void
    let onDelete: () -> Void

    init(card: SavedAimeCard, onSave: @escaping (SavedAimeCard) -> Void, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: card)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationView {
            Form {
                Section("卡片") {
                    TextField("卡片名称", text: $draft.label)
                        .textInputAutocapitalization(.never)
                    Text("\(draft.label.count)/30")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("删除卡", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        draft.label = String(draft.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
                        if draft.label.isEmpty {
                            draft.label = "AiMe 卡"
                        }
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct AboutView: View {
    @Environment(\.openURL) private var openURL
    let debugLogEndpoint: String?
    let selectedServerName: String?
    @State private var uploadState: DebugLogUploadState = .idle

    private let testFlightURL = URL(string: "https://beta.itunes.apple.com/v1/app/6783402915")
    private let testFlightFallbackURL = URL(string: "https://apps.apple.com/app/testflight/id899247664")

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.1"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image("AppIconPreview")
                        .resizable()
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .cyan.opacity(0.24), radius: 22)
                    Text("NFCAiME")
                        .font(.title.bold())
                    Text("AiMe 本地读卡与卡包工具")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                AboutSection(title: "应用信息") {
                    AboutRow(label: "版本", value: "\(version) (Build \(build))")
                    AboutLinkRow(label: "开发", title: "HashCat Team", url: URL(string: "https://github.com/Project-HashCat")!)
                    AboutRow(label: "当前平台", value: "iOS")
                }

                AboutSection(title: "本次更新") {
                    AboutRow(label: "新增", value: "本地保存卡片与手动上传错误日志")
                }

                AboutSection(title: "错误日志") {
                    Button(action: uploadDebugLogs) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "lock.doc")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("上传错误日志")
                                    .font(.body)
                                Text(selectedServerName.map { "将上传到：\($0)" } ?? "请先在刷卡设置中选择远端服务器")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            uploadIndicator
                        }
                        .foregroundStyle(.primary)
                        .padding(.vertical, 12)
                    }
                    .disabled(uploadState == .uploading || debugLogEndpoint?.isEmpty != false)
                    if let message = uploadState.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(uploadState.isError ? .red : .green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)
                    }
                }

                AboutSection(title: "链接") {
                    AboutRow(label: "TestFlight", value: "NFCAiME")
                    Button {
                        if let url = testFlightURL {
                            openURL(url)
                        } else if let url = testFlightFallbackURL {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Label("检查更新", systemImage: "arrow.clockwise")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                        .padding(.vertical, 14)
                    }
                }

                VStack(spacing: 8) {
                    Text("Made with ❤️ in SwiftUI")
                    Text("© 2026 HashCat Team")
                        .foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }
            .padding(24)
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var uploadIndicator: some View {
        switch uploadState {
        case .idle:
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .uploading:
            ProgressView()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func uploadDebugLogs() {
        guard let debugLogEndpoint, !debugLogEndpoint.isEmpty else {
            uploadState = .failure("请先选择远端服务器")
            return
        }
        uploadState = .uploading
        Task {
            do {
                try await CardAPI.uploadDebugLogs(to: debugLogEndpoint)
                uploadState = .success("错误日志已上传")
            } catch {
                uploadState = .failure(error.localizedDescription)
            }
        }
    }
}

private enum DebugLogUploadState: Equatable {
    case idle
    case uploading
    case success(String)
    case failure(String)

    var message: String? {
        switch self {
        case .idle, .uploading:
            return nil
        case .success(let message), .failure(let message):
            return message
        }
    }

    var isError: Bool {
        if case .failure = self { return true }
        return false
    }
}

private struct AboutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

private struct AboutRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color(.separator).opacity(0.35))
        }
    }
}

private struct AboutLinkRow: View {
    let label: String
    let title: String
    let url: URL

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            Link(title, destination: url)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color(.separator).opacity(0.35))
        }
    }
}

#if DEBUG
private struct DebugLogSection: View {
    let logs: [String]
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("调试日志", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = logs.reversed().joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(logs.isEmpty)
                .accessibilityLabel("复制调试日志")
                Button(role: .destructive, action: onClear) {
                    Image(systemName: "trash")
                }
                .disabled(logs.isEmpty)
                .accessibilityLabel("清空调试日志")
            }

            if logs.isEmpty {
                Text("点击开始读卡后，这里会显示 NFC 与网络的分阶段信息。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
#endif

private struct ReaderHeader: View {
    let phase: CardReader.ScanPhase

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: phase.symbol)
                .font(.system(size: 38))
                .foregroundStyle(phase.color)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("读取 AiMe 卡片")
                    .font(.title2.bold())
                Text("将卡片贴近 iPhone 顶部")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScanButton: View {
    let phase: CardReader.ScanPhase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: phase.isBusy ? "dot.radiowaves.left.and.right" : "wave.3.right")
                Text(phase.buttonTitle)
                Spacer()
                if !phase.isBusy {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
        }
        .disabled(phase.isBusy)
        .modifier(PrimaryButtonStyle())
    }
}

private struct StatusBanner: View {
    let phase: CardReader.ScanPhase

    @ViewBuilder
    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .scanning:
            status("等待读取卡片", color: .blue, showsProgress: true)
        case .submitting:
            status("正在请求服务器", color: .orange, showsProgress: true)
        case .complete:
            status("读取完成", color: .green, showsProgress: false)
        case .error(let message):
            status(message, color: .red, showsProgress: false)
        }
    }

    private func status(_ text: String, color: Color, showsProgress: Bool) -> some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView().tint(color)
            } else {
                Image(systemName: phase.symbol)
            }
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PrimaryButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
#else
        content.buttonStyle(.borderedProminent)
#endif
    }
}

private extension CardReader.ScanPhase {
    var buttonTitle: String {
        switch self {
        case .scanning: return "正在读卡"
        case .submitting: return "正在请求服务器"
        default: return "开始读卡"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "wave.3.right.circle"
        case .scanning: return "dot.radiowaves.left.and.right"
        case .submitting: return "arrow.triangle.2.circlepath"
        case .complete: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .cyan
        case .scanning: return .blue
        case .submitting: return .orange
        case .complete: return .green
        case .error: return .red
        }
    }
}

#if DEBUG
private extension CardReader.ScanRecord {
    static let previewSuccess = Self(
        timestamp: .now,
        code: "A1B2C3D4E5F6G7H8",
        idm: "01:2E:61:10:96:99:B0:8A",
        ckv: "01 23 45 67 89 AB CD EF",
        wcnt: "00 00 00 00 00 00 00 01",
        maca: "12 34 56 78 9A BC DE F0",
        accessCode: "01 23 45 67 89 01 23 45 67 89",
        spad0AccessCode: "01 23 45 67 89 01 23 45 67 89",
        konamiCardNumber: "GC26NZJ14DD9DC2L",
        privateNetworkNumber: "00085112316013866126",
        spad0Error: nil,
        accessCodeMatchesSpad0: true,
        remoteMessage: "同步完成",
        remoteFields: [
            CardResponseDisplayItem(label: "Server", value: "Example")
        ],
        error: nil
    )

    static let previewError = Self(
        timestamp: .now,
        code: "H8G7F6E5D4C3B2A1",
        idm: "01:2E:61:10:96:99:B0:8A",
        ckv: "01 23 45 67 89 AB CD EF",
        wcnt: "00 00 00 00 00 00 00 01",
        maca: "12 34 56 78 9A BC DE F0",
        accessCode: nil,
        spad0AccessCode: nil,
        konamiCardNumber: "GC26NZJ14DD9DC2L",
        privateNetworkNumber: "00085112316013866126",
        spad0Error: "Access Code 解析失败",
        accessCodeMatchesSpad0: nil,
        remoteMessage: nil,
        remoteFields: [],
        error: "服务器返回错误"
    )
}

#Preview("空状态") {
    ContentView(reader: CardReader(previewPhase: .idle, history: []))
}

#Preview("读卡中") {
    ContentView(reader: CardReader(previewPhase: .scanning, history: []))
}

#Preview("成功") {
    ContentView(reader: CardReader(previewPhase: .complete, history: [.previewSuccess]))
}

#Preview("服务器错误") {
    ContentView(reader: CardReader(previewPhase: .error("服务器返回错误"), history: [.previewError]))
}

#Preview("深色模式") {
    ContentView(reader: CardReader(previewPhase: .complete, history: [.previewSuccess]))
        .preferredColorScheme(.dark)
}

#Preview("大字体") {
    ContentView(reader: CardReader(previewPhase: .complete, history: [.previewSuccess]))
        .dynamicTypeSize(.accessibility2)
}
#endif
