import CryptoKit
import Foundation
import Security

enum CardAPIError: LocalizedError {
    case badURL
    case unreachable(String)
    case timeout
    case httpError(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "服务器地址格式无效"
        case .unreachable(let message):
            return "服务器不可达：\(message)"
        case .timeout:
            return "请求超时"
        case .httpError(let statusCode, let message):
            return "服务器返回错误（HTTP \(statusCode)）：\(message)"
        case .badResponse(let message):
            return "响应格式错误：\(message)"
        }
    }
}

struct CardPayload: Encodable, Sendable {
    let idm: String
    let rc: String
    let spad0: String?
    let spad0Encrypted: String?
    let spad0AccessCode: String?
    let idBlock: String
    let ckv: String
    let wcnt: String
    let maca: String
    let companyCode = "01"
    let firmwareVersion = "02"
    let dfc: String

    func withEncryptedSpad0(publicKey: String) throws -> CardPayload {
        guard let spad0,
              let spad0Data = Data(hex: spad0),
              spad0Data.count == 16
        else {
            throw CardAPIError.badResponse("缺少可上传的卡片安全数据")
        }
        return CardPayload(
            idm: idm,
            rc: rc,
            spad0: nil,
            spad0Encrypted: try Spad0RSA.encrypt(spad0Data, publicKey: publicKey),
            spad0AccessCode: nil,
            idBlock: idBlock,
            ckv: ckv,
            wcnt: wcnt,
            maca: maca,
            dfc: dfc
        )
    }
}

struct CardResponseDisplayItem: Codable, Sendable, Equatable {
    let label: String
    let value: String
}

struct CardResponse: Decodable, Sendable {
    let ok: Bool
    let code: String?
    let accessCodeHex: String?
    let spad0AccessCodeHex: String?
    let spad0DecodeError: String?
    let accessCodeMatchesSpad0: Bool?
    let message: String?
    let display: [CardResponseDisplayItem]?
    let error: String?
}

enum CardAPI {
    private static let debugLogSecret = "NFCAimeDebugLog-v1"

    static func submit(_ payload: CardPayload, to endpoint: String) async throws -> CardResponse {
        var request = URLRequest(url: try validatedEndpoint(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await perform(request)
        if let cardResponse = try? JSONDecoder().decode(CardResponse.self, from: data) {
            if (200..<300).contains(response.statusCode) || !cardResponse.ok {
                return cardResponse
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CardAPIError.httpError(response.statusCode, responseMessage(from: data))
        }
        throw CardAPIError.badResponse(responseMessage(from: data))
    }

    static func uploadDebugLogs(to endpoint: String) async throws {
        let logs = EncryptedDebugLogStore.load()
        guard !logs.isEmpty else {
            throw CardAPIError.badResponse("暂无可上传的错误日志")
        }
        let payload = DebugLogPayload(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            platform: "iOS",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            logs: logs
        )
        let plaintext = try JSONEncoder().encode(payload)
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(debugLogSecret.utf8))))
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw CardAPIError.badResponse("错误日志加密失败")
        }

        let url = try siblingEndpoint("debug-log", from: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode([
            "payload": combined.base64EncodedString()
        ])
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CardAPIError.httpError(response.statusCode, responseMessage(from: data))
        }
    }

    static func testConnection(to endpoint: String) async throws {
        var components = URLComponents(url: try validatedEndpoint(endpoint), resolvingAgainstBaseURL: false)
        var path = components?.path.split(separator: "/").map(String.init) ?? []
        if !path.isEmpty {
            path.removeLast()
        }
        path.append("health")
        components?.path = "/" + path.joined(separator: "/")
        components?.query = nil
        components?.fragment = nil

        guard let healthURL = components?.url else {
            throw CardAPIError.badURL
        }
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CardAPIError.httpError(response.statusCode, responseMessage(from: data))
        }
    }

    static func validatedEndpoint(_ endpoint: String) throws -> URL {
        let value = normalizedEndpoint(endpoint)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              !components.path.isEmpty,
              components.path != "/",
              let url = components.url
        else {
            throw CardAPIError.badURL
        }
        return url
    }

    static func normalizedEndpoint(_ endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return value
        }
        if !value.contains("://") {
            value = "http://\(value)"
        }
        guard var components = URLComponents(string: value) else {
            return value
        }
        let pathParts = components.path.split(separator: "/").map(String.init)
        if pathParts.last != "card" && pathParts.last != "refeash-aime" {
            pathParts.isEmpty
                ? (components.path = "/card")
                : (components.path = "/" + (pathParts + ["card"]).joined(separator: "/"))
        }
        return components.string ?? value
    }

    static func localEndpointWarning(_ endpoint: String) -> String? {
        guard let url = URLComponents(string: normalizedEndpoint(endpoint)),
              let host = url.host?.lowercased()
        else {
            return nil
        }
        if host == "127.0.0.1" || host == "localhost" {
            return "手机上的 127.0.0.1 是手机自己，不是电脑。请填写运行 server 的电脑局域网 IP。"
        }
        if host.hasPrefix("192.168.") && host.hasSuffix(".1") {
            return "\(host) 通常是路由器地址，不是运行 server 的电脑地址。请填写电脑的局域网 IP，并确保 server 监听 0.0.0.0。"
        }
        return nil
    }

    private static func siblingEndpoint(_ lastPathComponent: String, from endpoint: String) throws -> URL {
        var components = URLComponents(url: try validatedEndpoint(endpoint), resolvingAgainstBaseURL: false)
        var path = components?.path.split(separator: "/").map(String.init) ?? []
        if !path.isEmpty {
            path.removeLast()
        }
        path.append(lastPathComponent)
        components?.path = "/" + path.joined(separator: "/")
        components?.query = nil
        components?.fragment = nil
        guard let url = components?.url else {
            throw CardAPIError.badURL
        }
        return url
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CardAPIError.badResponse("收到非 HTTP 响应")
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CardAPIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw CardAPIError.timeout
        } catch let error as URLError {
            throw CardAPIError.unreachable(error.localizedDescription)
        } catch {
            throw CardAPIError.unreachable(error.localizedDescription)
        }
    }

    private static func responseMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            let detail: String?
        }

        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let detail = envelope.detail,
           !detail.isEmpty {
            return detail
        }
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty ? "服务器返回空响应" : String(body.prefix(160))
    }

}

private struct DebugLogPayload: Encodable {
    let appVersion: String?
    let build: String?
    let platform: String
    let createdAt: String
    let logs: [String]
}

enum Spad0RSA {
    static func validatePublicKey(_ publicKey: String) throws {
        _ = try makePublicKey(publicKey)
    }

    static func encrypt(_ data: Data, publicKey: String) throws -> String {
        let key = try makePublicKey(publicKey)
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else {
            throw CardAPIError.badResponse("服务器 RSA 公钥不支持 OAEP-SHA256")
        }

        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key,
            algorithm,
            data as CFData,
            &error
        ) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "RSA 加密失败"
            throw CardAPIError.badResponse(message)
        }
        return encrypted.base64EncodedString()
    }

    private static func makePublicKey(_ publicKey: String) throws -> SecKey {
        guard let data = publicKeyData(from: publicKey), !data.isEmpty else {
            throw CardAPIError.badResponse("请配置服务器 RSA 公钥")
        }
        if let key = createPublicKey(from: data) {
            return key
        }
        if let rsaKeyData = stripX509Header(from: data),
           let key = createPublicKey(from: rsaKeyData) {
            return key
        }
        throw CardAPIError.badResponse("RSA 公钥格式无效")
    }

    private static func createPublicKey(from data: Data) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }

    private static func publicKeyData(from value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let base64 = trimmed
            .components(separatedBy: .newlines)
            .filter { !$0.contains("-----BEGIN") && !$0.contains("-----END") }
            .joined()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return Data(base64Encoded: base64)
    }

    private static func stripX509Header(from data: Data) -> Data? {
        var index = 0
        guard readASN1Tag(0x30, data: data, index: &index) != nil,
              let algorithmLength = readASN1Tag(0x30, data: data, index: &index)
        else { return nil }
        index += algorithmLength
        guard let bitStringLength = readASN1Tag(0x03, data: data, index: &index),
              bitStringLength > 1,
              index < data.count,
              data[index] == 0x00
        else { return nil }
        index += 1
        let keyLength = bitStringLength - 1
        guard index + keyLength <= data.count else { return nil }
        return data.subdata(in: index..<(index + keyLength))
    }

    private static func readASN1Tag(_ expectedTag: UInt8, data: Data, index: inout Int) -> Int? {
        guard index < data.count, data[index] == expectedTag else { return nil }
        index += 1
        guard index < data.count else { return nil }
        let firstLengthByte = data[index]
        index += 1
        if firstLengthByte < 0x80 {
            return Int(firstLengthByte)
        }
        let byteCount = Int(firstLengthByte & 0x7F)
        guard byteCount > 0, byteCount <= 4, index + byteCount <= data.count else { return nil }
        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) + Int(data[index])
            index += 1
        }
        return length
    }
}

extension Data {
    init?(hex: String) {
        let normalized = hex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard normalized.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    func displayHex(separator: String = " ") -> String {
        map { String(format: "%02X", $0) }.joined(separator: separator)
    }
}
