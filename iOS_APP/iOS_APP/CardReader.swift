@preconcurrency import CoreNFC
import Combine
import CryptoKit
import Foundation
import UIKit

private struct NFCReference<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
final class CardReader: NSObject, ObservableObject {
    enum ScanPhase: Equatable, Sendable {
        case idle
        case scanning
        case submitting
        case complete
        case error(String)

        var isBusy: Bool {
            self == .scanning || self == .submitting
        }
    }

    struct ScanRecord: Codable, Identifiable, Sendable {
        var id = UUID()
        let timestamp: Date
        let code: String?
        let idm: String
        let ckv: String
        let wcnt: String
        let maca: String
        let accessCode: String?
        let spad0AccessCode: String?
        let konamiCardNumber: String?
        let privateNetworkNumber: String?
        let spad0Error: String?
        let accessCodeMatchesSpad0: Bool?
        let remoteMessage: String?
        let remoteFields: [CardResponseDisplayItem]?
        let error: String?

        var compactAccessCode: String? {
            accessCode.map { $0.filter { !$0.isWhitespace } }
        }

        var displayAccessCode: String? {
            Self.displayAccessCode(compactAccessCode)
        }

        var compactSpad0AccessCode: String? {
            spad0AccessCode.map { $0.filter { !$0.isWhitespace } }
        }

        var displaySpad0AccessCode: String? {
            Self.displayAccessCode(compactSpad0AccessCode)
        }

        var displayKonamiCardNumber: String? {
            guard let konamiCardNumber else { return nil }
            return Self.displayAccessCode(konamiCardNumber)
        }

        var displayPrivateNetworkNumber: String? {
            guard let privateNetworkNumber else { return nil }
            return Self.displayAccessCode(privateNetworkNumber)
        }

        var accessCodeCheckText: String? {
            guard let accessCodeMatchesSpad0 else { return nil }
            return accessCodeMatchesSpad0 ? "Verity Success" : "Verity Failed"
        }

        private static func displayAccessCode(_ compactValue: String?) -> String? {
            guard let value = compactValue else { return nil }
            return stride(from: 0, to: value.count, by: 4).map { offset in
                let start = value.index(value.startIndex, offsetBy: offset)
                let end = value.index(start, offsetBy: min(4, value.count - offset))
                return String(value[start..<end])
            }
            .joined(separator: " ")
        }

        var exportText: String {
            [
                code.map { "#\($0)" },
                "IDM: \(idm)",
                "CKV: \(ckv)",
                "WCNT: \(wcnt)",
                "MACA: \(maca)",
                "ACCESS CODE: \(displayAccessCode ?? "-")",
                "PRIVATE NETWORK: \(displayPrivateNetworkNumber ?? "-")",
                "KONAMI CARD NUMBER: \(displayKonamiCardNumber ?? "-")",
                accessCodeCheckText.map { "CHECK: \($0)" },
                remoteMessage.map { "SERVER MESSAGE: \($0)" },
                (remoteFields ?? []).isEmpty ? nil : (remoteFields ?? []).map { "\($0.label): \($0.value)" }.joined(separator: "\n"),
                error.map { "ERROR: \($0)" },
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        }
    }

    @Published private(set) var phase: ScanPhase = .idle
    @Published private(set) var history: [ScanRecord] = []
    private var debugLogs: [String] = []

    private static let historyKey = "scanHistory"
    private static let maxHistory = 10
    private static let maxDebugLogs = 200
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var session: NFCTagReaderSession?
    private var scanTimeoutTask: Task<Void, Never>?
    private var serverMode: ServerMode = .local
    private var serverURL = ""
    private var serverPublicKey = ""
    private let persistsHistory: Bool

    override init() {
        persistsHistory = true
        super.init()
        loadHistory()
        debugLogs = EncryptedDebugLogStore.load()
    }

    init(previewPhase: ScanPhase, history: [ScanRecord]) {
        phase = previewPhase
        self.history = history
        persistsHistory = false
        super.init()
    }

    func scan(mode: ServerMode, serverURL: String, serverPublicKey: String?) {
        guard !phase.isBusy else {
            debugLog("忽略重复扫描请求：当前阶段=\(String(describing: phase))")
            return
        }
        let endpointDescription = mode == .local ? "本地读取" : serverURL
        debugLog("开始扫描：mode=\(mode.title), endpoint=\(endpointDescription)")
        if mode == .remote {
            guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                report("请先添加并选择远端服务器")
                return
            }
            guard let publicKey = serverPublicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !publicKey.isEmpty
            else {
                report("请先配置远端服务器 RSA 公钥")
                return
            }
            do {
                _ = try CardAPI.validatedEndpoint(serverURL)
                try Spad0RSA.validatePublicKey(publicKey)
            } catch {
                debugLog("服务器地址校验失败：\(String(reflecting: error))")
                report(error.localizedDescription)
                return
            }
        }
        guard NFCTagReaderSession.readingAvailable else {
            debugLog("NFCTagReaderSession.readingAvailable=false")
            report("此设备不支持 NFC 读卡")
            return
        }

        self.serverMode = mode
        self.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverPublicKey = serverPublicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        phase = .scanning
        guard let session = NFCTagReaderSession(pollingOption: .iso18092, delegate: self) else {
            debugLog("NFCTagReaderSession 初始化失败")
            report("无法启动 NFC 读卡会话")
            return
        }
        session.alertMessage = "请将 AiMe 卡片贴近 iPhone 顶部"
        self.session = session
        debugLog("NFC 会话已创建，polling=.iso18092，systemCodes=88B4/0003，调用 begin()")
        session.begin()
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
            guard let self,
                  case .scanning = self.phase,
                  let session = self.session
            else {
                return
            }
            self.debugLog("达到 App 设定的 30 秒扫描超时")
            self.report("读卡超时，请重新贴卡尝试")
            session.invalidate(errorMessage: "读卡超时，请重新贴卡尝试")
        }
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func append(_ record: ScanRecord) {
        history.insert(record, at: 0)
        history = Array(history.prefix(Self.maxHistory))
        saveHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let records = try? JSONDecoder().decode([ScanRecord].self, from: data)
        else {
            return
        }
        history = Array(records.prefix(Self.maxHistory))
    }

    private func saveHistory() {
        guard persistsHistory else { return }
        guard !history.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.historyKey)
            return
        }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func report(_ message: String) {
        debugLog("错误：\(message)")
        phase = .error(message)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    nonisolated private func invalidate(_ session: NFCTagReaderSession, message: String) {
        debugLogFromCallback("请求会话失效：\(message)")
        Task { @MainActor [weak self] in
            self?.report(message)
        }
        session.invalidate(errorMessage: String(message.prefix(100)))
    }

    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    private func notifyCardRead() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func debugLog(_ message: String) {
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        debugLogs.insert(line, at: 0)
        debugLogs = Array(debugLogs.prefix(Self.maxDebugLogs))
        EncryptedDebugLogStore.save(debugLogs)
#if DEBUG
        print("[NFCAime] \(line)")
#endif
    }

    nonisolated private func debugLogFromCallback(_ message: String) {
        Task { @MainActor [weak self] in
            self?.debugLog(message)
        }
    }
}

enum EncryptedDebugLogStore {
    private static let key = "encryptedDebugLogs"
    private static let secret = "NFCAimeDebugLog-v1"

    static func load() -> [String] {
        guard let encoded = UserDefaults.standard.string(forKey: key),
              let sealedData = Data(base64Encoded: encoded),
              let sealedBox = try? AES.GCM.SealedBox(combined: sealedData),
              let plaintext = try? AES.GCM.open(sealedBox, using: symmetricKey),
              let logs = try? JSONDecoder().decode([String].self, from: plaintext)
        else {
            return []
        }
        return logs
    }

    static func save(_ logs: [String]) {
        guard !logs.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(logs),
              let sealedBox = try? AES.GCM.seal(data, using: symmetricKey),
              let combined = sealedBox.combined
        else {
            return
        }
        UserDefaults.standard.set(combined.base64EncodedString(), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static var symmetricKey: SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
    }
}

extension CardReader: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        debugLogFromCallback("NFC 会话已激活")
    }

    nonisolated func tagReaderSession(
        _ session: NFCTagReaderSession,
        didInvalidateWithError error: Error
    ) {
        let details: String
        if let readerError = error as? NFCReaderError {
            details = "NFCReaderError code=\(readerError.code.rawValue), message=\(error.localizedDescription)"
        } else {
            details = "\(String(reflecting: type(of: error))): \(error.localizedDescription)"
        }
        debugLogFromCallback("NFC 会话结束：\(details)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scanTimeoutTask?.cancel()
            self.scanTimeoutTask = nil
            self.session = nil
            guard case .scanning = self.phase else { return }

            if let readerError = error as? NFCReaderError,
               readerError.code == .readerSessionInvalidationErrorUserCanceled {
                self.debugLog("用户取消 NFC 会话，状态恢复 idle")
                self.phase = .idle
            } else {
                self.report(error.localizedDescription)
            }
        }
    }

    nonisolated func tagReaderSession(
        _ session: NFCTagReaderSession,
        didDetect tags: [NFCTag]
    ) {
        debugLogFromCallback("检测到标签：count=\(tags.count)")
        guard tags.count == 1 else {
            debugLogFromCallback("检测到多张标签，重新轮询")
            session.alertMessage = "一次只能读取一张卡片"
            session.restartPolling()
            return
        }
        guard case let .feliCa(tag) = tags[0] else {
            debugLogFromCallback("标签类型不是 FeliCa：\(String(describing: tags[0]))")
            invalidate(session, message: "检测到的不是 FeliCa 卡片")
            return
        }
        Task { @MainActor [weak self] in
            self?.scanTimeoutTask?.cancel()
            self?.scanTimeoutTask = nil
        }
        debugLogFromCallback(
            "发现 FeliCa：IDm=\(tag.currentIDm.hex), systemCode=\(tag.currentSystemCode.hex)"
        )

        let sessionReference = NFCReference(value: session)
        let tagReference = NFCReference(value: tag)
        debugLogFromCallback("开始连接 FeliCa 标签")
        session.connect(to: tags[0]) { [self, sessionReference, tagReference] error in
            if let error {
                debugLogFromCallback("连接失败：\(String(reflecting: error))")
                invalidate(
                    sessionReference.value,
                    message: "连接卡片失败：\(error.localizedDescription)"
                )
                return
            }
            debugLogFromCallback("FeliCa 标签连接成功")
            writeRCAndRead(tagReference.value, session: sessionReference.value)
        }
    }

    nonisolated private func writeRCAndRead(
        _ tag: NFCFeliCaTag,
        session: NFCTagReaderSession
    ) {
        let sessionReference = NFCReference(value: session)
        let tagReference = NFCReference(value: tag)
        let rc = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        debugLogFromCallback("写入 RC：service=0900, block=0080, rc=\(rc.hex)")
        tag.writeWithoutEncryption(
            serviceCodeList: [Data([0x09, 0x00])],
            blockList: [Data([0x80, 0x80])],
            blockData: [rc]
        ) { [self, sessionReference, tagReference] status1, status2, error in
            debugLogFromCallback(
                "写 RC 回调：status=\(status1.hexByte) \(status2.hexByte), error=\(error?.localizedDescription ?? "nil")"
            )
            guard error == nil, status1 == 0, status2 == 0 else {
                let message = error?.localizedDescription ?? "写入 RC 失败（\(status1), \(status2)）"
                invalidate(sessionReference.value, message: message)
                return
            }

            debugLogFromCallback("读取 SPAD0：service=0B00, block=00")
            tagReference.value.readWithoutEncryption(
                serviceCodeList: [Data([0x0B, 0x00])],
                blockList: [Data([0x80, 0x00])]
            ) { [self, sessionReference, tagReference] status1, status2, blocks, error in
                debugLogFromCallback(
                    "读 SPAD0 回调：status=\(status1.hexByte) \(status2.hexByte), count=\(blocks.count), lengths=\(blocks.map(\.count)), error=\(error?.localizedDescription ?? "nil")"
                )
                let spad0Block: Data?
                if error == nil,
                   status1 == 0,
                   status2 == 0,
                   blocks.count == 1,
                   blocks[0].count == 16 {
                    debugLogFromCallback("SPAD0 block=\(blocks[0].hex)")
                    spad0Block = blocks[0]
                } else {
                    debugLogFromCallback(
                        "SPAD0 读取失败，继续读取认证块：\(error?.localizedDescription ?? "status \(status1.hexByte) \(status2.hexByte)")"
                    )
                    spad0Block = nil
                }

                readSecurityBlocks(
                    tagReference.value,
                    session: sessionReference.value,
                    rc: rc,
                    spad0Block: spad0Block
                )
            }
        }
    }

    nonisolated private func readSecurityBlocks(
        _ tag: NFCFeliCaTag,
        session: NFCTagReaderSession,
        rc: Data,
        spad0Block: Data?
    ) {
        let blockNumbers: [UInt8] = [0x82, 0x86, 0x90, 0x91]
        let sessionReference = NFCReference(value: session)
        let tagReference = NFCReference(value: tag)
        debugLogFromCallback("读取认证块：service=0B00, blocks=82/86/90/91")
        tag.readWithoutEncryption(
            serviceCodeList: [Data([0x0B, 0x00])],
            blockList: blockNumbers.map { Data([0x80, $0]) }
        ) { [self, sessionReference, tagReference] status1, status2, blocks, error in
            debugLogFromCallback(
                "读认证块回调：status=\(status1.hexByte) \(status2.hexByte), count=\(blocks.count), lengths=\(blocks.map(\.count)), error=\(error?.localizedDescription ?? "nil")"
            )
            if error == nil,
               status1 == 0,
               status2 == 0,
               blocks.count == blockNumbers.count,
               blocks.allSatisfy({ $0.count == 16 }) {
                finishSecurityBlocks(
                    blocks,
                    tag: tagReference.value,
                    session: sessionReference.value,
                    rc: rc,
                    spad0Block: spad0Block
                )
                return
            }

            debugLogFromCallback(
                "认证块批量读取失败，降级为单块读取：\(error?.localizedDescription ?? "status \(status1.hexByte) \(status2.hexByte)")"
            )
            readSecurityBlocksOneByOne(
                tagReference.value,
                session: sessionReference.value,
                rc: rc,
                spad0Block: spad0Block,
                remainingBlocks: blockNumbers,
                collectedBlocks: []
            )
        }
    }

    nonisolated private func readSecurityBlocksOneByOne(
        _ tag: NFCFeliCaTag,
        session: NFCTagReaderSession,
        rc: Data,
        spad0Block: Data?,
        remainingBlocks: [UInt8],
        collectedBlocks: [Data]
    ) {
        guard let blockNumber = remainingBlocks.first else {
            finishSecurityBlocks(
                collectedBlocks,
                tag: tag,
                session: session,
                rc: rc,
                spad0Block: spad0Block
            )
            return
        }

        let sessionReference = NFCReference(value: session)
        let tagReference = NFCReference(value: tag)
        debugLogFromCallback("读取认证块单块：service=0B00, block=\(blockNumber.hexByte)")
        tag.readWithoutEncryption(
            serviceCodeList: [Data([0x0B, 0x00])],
            blockList: [Data([0x80, blockNumber])]
        ) { [self, sessionReference, tagReference] status1, status2, blocks, error in
            debugLogFromCallback(
                "读认证块单块回调：block=\(blockNumber.hexByte), status=\(status1.hexByte) \(status2.hexByte), count=\(blocks.count), lengths=\(blocks.map(\.count)), error=\(error?.localizedDescription ?? "nil")"
            )
            guard error == nil,
                  status1 == 0,
                  status2 == 0,
                  blocks.count == 1,
                  blocks[0].count == 16
            else {
                let message = error?.localizedDescription
                    ?? (status1 == 0 && status2 == 0
                        ? "读取卡片数据格式错误"
                        : "读取卡片数据失败（\(status1), \(status2)）")
                invalidate(sessionReference.value, message: message)
                return
            }

            readSecurityBlocksOneByOne(
                tagReference.value,
                session: sessionReference.value,
                rc: rc,
                spad0Block: spad0Block,
                remainingBlocks: Array(remainingBlocks.dropFirst()),
                collectedBlocks: collectedBlocks + [blocks[0]]
            )
        }
    }

    nonisolated private func finishSecurityBlocks(
        _ blocks: [Data],
        tag: NFCFeliCaTag,
        session: NFCTagReaderSession,
        rc: Data,
        spad0Block: Data?
    ) {
        for (index, block) in blocks.enumerated() {
            debugLogFromCallback("securityBlock[\(index)]=\(block.hex)")
        }
        Task { @MainActor in notifyCardRead() }
        Task { @MainActor [weak self] in
            session.alertMessage = self?.serverMode == .local ? "读卡完成" : "读卡成功，正在查询服务器"
        }
        submit(
            tag: tag,
            rc: rc,
            spad0Block: spad0Block,
            securityBlocks: blocks,
            session: session
        )
    }

    nonisolated private func submit(
        tag: NFCFeliCaTag,
        rc: Data,
        spad0Block: Data?,
        securityBlocks blocks: [Data],
        session: NFCTagReaderSession
    ) {
        let idBlock = blocks[0]
        let idm = tag.currentIDm.displayHex(separator: ":")
        let ckv = blocks[1].displayHex()
        let wcnt = blocks[2].displayHex()
        let maca = Data(blocks[3].prefix(8)).displayHex()
        let spad0Hex = spad0Block?.hex
        debugLogFromCallback("SPAD0：encrypted=\(spad0Hex ?? "nil")")
        let payload = CardPayload(
            idm: tag.currentIDm.hex,
            rc: rc.hex,
            spad0: spad0Hex,
            spad0Encrypted: nil,
            spad0AccessCode: nil,
            idBlock: idBlock.hex,
            ckv: blocks[1].hex,
            wcnt: blocks[2].hex,
            maca: Data(blocks[3].prefix(8)).hex,
            dfc: idBlock.subdata(in: 8..<10).hex
        )
        let sessionReference = NFCReference(value: session)

        Task { @MainActor [weak self, sessionReference] in
            guard let self else { return }
            if self.serverMode == .local {
                self.debugLog("本地读取完成：idm=\(payload.idm)")
                self.append(ScanRecord(
                    timestamp: Date(),
                    code: nil,
                    idm: idm,
                    ckv: ckv,
                    wcnt: wcnt,
                    maca: maca,
                    accessCode: nil,
                    spad0AccessCode: nil,
                    konamiCardNumber: nil,
                    privateNetworkNumber: nil,
                    spad0Error: nil,
                    accessCodeMatchesSpad0: nil,
                    remoteMessage: nil,
                    remoteFields: [],
                    error: nil
                ))
                self.phase = .complete
                self.notify(.success)
                sessionReference.value.alertMessage = "读取完成"
                sessionReference.value.invalidate()
                return
            }

            self.phase = .submitting
            let endpointDescription = self.serverURL
            let remotePayload: CardPayload
            do {
                remotePayload = try payload.withEncryptedSpad0(publicKey: self.serverPublicKey)
            } catch {
                self.append(ScanRecord(
                    timestamp: Date(),
                    code: nil,
                    idm: idm,
                    ckv: ckv,
                    wcnt: wcnt,
                    maca: maca,
                    accessCode: nil,
                    spad0AccessCode: nil,
                    konamiCardNumber: nil,
                    privateNetworkNumber: nil,
                    spad0Error: nil,
                    accessCodeMatchesSpad0: nil,
                    remoteMessage: nil,
                    remoteFields: [],
                    error: error.localizedDescription
                ))
                self.report(error.localizedDescription)
                sessionReference.value.invalidate(
                    errorMessage: String(error.localizedDescription.prefix(100))
                )
                return
            }
            self.debugLog(
                "提交：mode=\(self.serverMode.title), endpoint=\(endpointDescription), idm=\(remotePayload.idm), rc=\(remotePayload.rc), spad0Encrypted=\(remotePayload.spad0Encrypted == nil ? "nil" : "present"), spad0AccessCode=\(remotePayload.spad0AccessCode ?? "nil"), idBlock=\(remotePayload.idBlock), ckv=\(remotePayload.ckv), wcnt=\(remotePayload.wcnt), maca=\(remotePayload.maca), dfc=\(remotePayload.dfc)"
            )
            do {
                let response = try await CardAPI.submit(remotePayload, to: self.serverURL)
                let serverMatch = response.accessCodeMatchesSpad0.map { $0 ? "true" : "false" } ?? "nil"
                self.debugLog(
                    "服务器响应：ok=\(response.ok), code=\(response.code ?? "nil"), accessCode=\(response.accessCodeHex ?? "nil"), spad0AccessCode=\(response.spad0AccessCodeHex ?? "nil"), spad0DecodeError=\(response.spad0DecodeError ?? "nil"), match=\(serverMatch), error=\(response.error ?? "nil")"
                )
                let normalizedError = response.error?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let failureMessage = normalizedError.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "服务器返回未知错误"
                let responseError = response.ok ? nil : failureMessage
                let accessCode: String?
                if response.ok,
                   let value = response.accessCodeHex,
                   let data = Data(hex: value),
                   data.count == 10 {
                    accessCode = value.uppercased()
                } else {
                    accessCode = nil
                }
                let serverSpad0AccessCode: String?
                if let value = response.spad0AccessCodeHex,
                   let data = Data(hex: value),
                   data.count == 10 {
                    serverSpad0AccessCode = value.uppercased()
                } else {
                    serverSpad0AccessCode = nil
                }
                self.append(ScanRecord(
                    timestamp: Date(),
                    code: response.code,
                    idm: idm,
                    ckv: ckv,
                    wcnt: wcnt,
                    maca: maca,
                    accessCode: accessCode,
                    spad0AccessCode: serverSpad0AccessCode,
                    konamiCardNumber: nil,
                    privateNetworkNumber: nil,
                    spad0Error: response.spad0DecodeError,
                    accessCodeMatchesSpad0: response.accessCodeMatchesSpad0,
                    remoteMessage: response.message,
                    remoteFields: response.display ?? [],
                    error: responseError
                ))

                self.phase = response.ok ? .complete : .error(failureMessage)
                self.notify(response.ok ? .success : .error)
                sessionReference.value.alertMessage = response.ok ? "查询完成" : "服务器返回错误"
                sessionReference.value.invalidate()
            } catch is CancellationError {
                self.debugLog("服务器请求被取消")
                self.phase = .idle
                sessionReference.value.invalidate()
            } catch {
                self.debugLog(
                    "服务器请求失败：type=\(String(reflecting: type(of: error))), detail=\(String(reflecting: error))"
                )
                self.append(ScanRecord(
                    timestamp: Date(),
                    code: nil,
                    idm: idm,
                    ckv: ckv,
                    wcnt: wcnt,
                    maca: maca,
                    accessCode: nil,
                    spad0AccessCode: nil,
                    konamiCardNumber: nil,
                    privateNetworkNumber: nil,
                    spad0Error: nil,
                    accessCodeMatchesSpad0: nil,
                    remoteMessage: nil,
                    remoteFields: [],
                    error: error.localizedDescription
                ))
                self.report(error.localizedDescription)
                sessionReference.value.invalidate(
                    errorMessage: String(error.localizedDescription.prefix(100))
                )
            }
        }
    }
}

private extension Int {
    var hexByte: String {
        String(format: "%02X", self)
    }
}

private extension UInt8 {
    var hexByte: String {
        String(format: "%02X", self)
    }
}
