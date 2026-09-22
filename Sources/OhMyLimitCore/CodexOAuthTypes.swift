import Foundation
import Security

/// Public installed-app client configuration used by the Codex CLI ChatGPT login.
/// These identify the OAuth client; user authorization tokens are stored only in Keychain.
public enum CodexOAuthConfiguration {
    public static let issuer = "https://auth.openai.com"
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    public static let originator = "codex_cli_rs"
    /// Registered redirect URI allow-list for the Codex CLI client.
    public static let callbackPorts: [UInt16] = [1455, 1457]
    public static let callbackPath = "/auth/callback"
    public static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
}

public struct CodexOAuthCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let accountID: String
    public let email: String
    public let planType: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date,
                accountID: String, email: String, planType: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
        self.planType = planType
    }

    public var identity: CodexIdentity {
        CodexIdentity(email: email, planType: planType, accountID: accountID)
    }
}

public enum CodexOAuthError: Error, LocalizedError, Equatable, Sendable {
    case signInRequired
    case userCancelled
    case timedOut
    case callbackUnavailable
    case invalidResponse
    case networkFailure
    case authorizationFailed(Int)
    case storageFailure(Int32)

    var needsKeychainAccess: Bool {
        guard case .storageFailure(let status) = self else { return false }
        return status == errSecInteractionNotAllowed || status == errSecInteractionRequired
            || status == errSecAuthFailed || status == errSecUserCanceled
    }

    public var errorDescription: String? {
        switch self {
        case .signInRequired: "ChatGPT 계정에 다시 로그인해 주세요."
        case .userCancelled: "ChatGPT 로그인을 취소했습니다."
        case .timedOut: "ChatGPT 로그인 또는 조회 시간이 초과되었습니다. 다시 시도해 주세요."
        case .callbackUnavailable: "ChatGPT 로그인 응답을 받을 수 없습니다. 다시 시도해 주세요."
        case .invalidResponse: "ChatGPT 인증 또는 사용량 응답을 확인할 수 없습니다."
        case .networkFailure: "OpenAI 서버에 연결할 수 없습니다. 네트워크를 확인해 주세요."
        case .authorizationFailed(let status): "ChatGPT 인증 요청에 실패했습니다 (HTTP \(status))."
        case .storageFailure where needsKeychainAccess:
            "키체인 접근 권한이 필요합니다. 키체인 접근 허용 버튼을 눌러 Oh My Limit의 접근을 허용해 주세요. 키체인이 잠겨 있다면 먼저 잠금을 해제해 주세요."
        case .storageFailure(let status): "로그인 정보를 키체인에 저장하거나 읽지 못했습니다 (코드 \(status))."
        }
    }
}
