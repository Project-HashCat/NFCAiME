import SwiftUI
import UIKit

struct ScanResultCard: View {
    let record: CardReader.ScanRecord
    var privacyMode = false
    var isSaved = false
    var onSave: (() -> Void)?
    @State private var copiedCode = false
    @State private var copiedField: String?
    @State private var showsShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("最近结果", systemImage: record.error == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(record.error == nil ? .green : .orange)
                Spacer()
                Button {
                    showsShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享完整结果")
            }

            if let code = record.code, !code.isEmpty {
                HStack(spacing: 8) {
                    Text("#CARD \(code)")
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        copyCode(code)
                    } label: {
                        Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("复制 #CARD")
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 12) {
                ResultField(
                    label: "IDM",
                    value: record.idm,
                    privacyMode: privacyMode,
                    copied: copiedField == "IDM"
                ) {
                    copyField("IDM", value: record.idm)
                }
                ResultField(
                    label: "Access Code",
                    value: record.displayAccessCode ?? "-",
                    privacyMode: privacyMode,
                    copied: copiedField == "Access Code",
                    onLongPress: record.compactAccessCode.map { value in
                        { copyField("Access Code", value: value) }
                    }
                )
                if let privateNetworkNumber = record.displayPrivateNetworkNumber,
                   let rawPrivateNetworkNumber = record.privateNetworkNumber {
                    ResultField(
                        label: "Private Network",
                        value: privateNetworkNumber,
                        privacyMode: privacyMode,
                        copied: copiedField == "Private Network",
                        onLongPress: { copyField("Private Network", value: rawPrivateNetworkNumber) }
                    )
                }
                if let konamiCardNumber = record.displayKonamiCardNumber,
                   let rawKonamiCardNumber = record.konamiCardNumber {
                    ResultField(
                        label: "Konami Card Number",
                        value: konamiCardNumber,
                        privacyMode: privacyMode,
                        copied: copiedField == "Konami Card Number",
                        onLongPress: { copyField("Konami Card Number", value: rawKonamiCardNumber) }
                    )
                }
                if let checkText = record.accessCodeCheckText {
                    Text(checkText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(record.accessCodeMatchesSpad0 == true ? .green : .red)
                }
                if let remoteMessage = record.remoteMessage, !remoteMessage.isEmpty {
                    Text(remoteMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                let remoteFields = record.remoteFields ?? []
                if !remoteFields.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务器返回")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(remoteFields.enumerated()), id: \.offset) { _, item in
                            ResultField(label: item.label, value: item.value)
                        }
                    }
                    .padding(.top, 4)
                }
                Text("长按 IDM、Access Code、Private Network 或 Konami Card Number 可复制")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = record.error {
                Text("ERROR: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let onSave {
                Button(action: onSave) {
                    Label(isSaved ? "已保存" : "保存卡片", systemImage: isSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaved)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showsShareSheet) {
            ActivityView(items: [record.exportText])
        }
    }

    private func copyCode(_ code: String) {
        UIPasteboard.general.string = code
        copiedCode = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copiedCode = false
        }
    }

    private func copyField(_ field: String, value: String) {
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

private struct ResultField: View {
    let label: String
    let value: String
    var privacyMode = false
    var copied = false
    var onLongPress: (() -> Void)?
    @State private var isRevealed = false

    private var displayValue: String {
        privacyMode && !isRevealed ? PrivacyMask.lastFour(value) : value
    }

    @ViewBuilder
    var body: some View {
        if let onLongPress {
            row
                .contentShape(Rectangle())
                .onLongPressGesture(perform: onLongPress)
        } else {
            row.textSelection(.enabled)
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(displayValue)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            if privacyMode {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye" : "eye.slash")
                }
                .buttonStyle(.plain)
            }
            if copied {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ viewController: UIActivityViewController, context: Context) {}
}

struct ScanHistorySection: View {
    let records: [CardReader.ScanRecord]
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("更早记录", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button(role: .destructive, action: onClear) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("清空读卡记录")
            }

            ForEach(records) { record in
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.code.map { "#\($0)" } ?? "本地读取")
                            .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        Text("IDM: \(record.idm)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(record.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
