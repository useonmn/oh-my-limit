import Foundation
import Security

public struct AntigravityOAuthConfiguration: Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    // Public installed-app client configuration distributed by Antigravity Tools.
    // https://github.com/lbjlaq/Antigravity-Manager/blob/734e2bde5d60cd7ecffe2467b5cab9cb154a3f5e/src-tauri/src/modules/oauth.rs
    // These identify the OAuth client; user authorization tokens are stored only in Keychain.
    public static let standard = AntigravityOAuthConfiguration(
        clientID: "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
        clientSecret: "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"
    )

    public static let scopes = [
        "openid",
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email"
    ]
}

public struct AntigravityOAuthCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let accountID: String
    public let email: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, accountID: String, email: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
    }

    public var identity: CodexIdentity { CodexIdentity(email: email, accountID: accountID) }
}

public enum AntigravityOAuthError: Error, LocalizedError, Equatable, Sendable {
    case signInRequired
    case userCancelled
    case timedOut
    case callbackUnavailable
    case invalidResponse
    case networkFailure
    case authorizationFailed(Int)
    case quotaUnavailable
    case storageFailure(Int32)

    var needsKeychainAccess: Bool {
        guard case .storageFailure(let status) = self else { return false }
        return status == errSecInteractionNotAllowed || status == errSecInteractionRequired
            || status == errSecAuthFailed || status == errSecUserCanceled
    }

    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Google 계정에 다시 로그인해 주세요."
        case .userCancelled: "Google 로그인을 취소했습니다."
        case .timedOut: "Google 로그인 또는 조회 시간이 초과되었습니다. 다시 시도해 주세요."
        case .callbackUnavailable: "Google 로그인 응답을 받을 수 없습니다. 다시 시도해 주세요."
        case .invalidResponse: "Google 인증 또는 사용량 응답을 확인할 수 없습니다."
        case .networkFailure: "Google 서버에 연결할 수 없습니다. 네트워크를 확인해 주세요."
        case .authorizationFailed(let status): "Google 인증 요청에 실패했습니다 (HTTP \(status))."
        case .quotaUnavailable: "이 계정의 Antigravity 한도 정보를 제공받지 못했습니다."
        case .storageFailure where needsKeychainAccess:
            "키체인 접근 권한이 필요합니다. 키체인 접근 허용 버튼을 눌러 Oh My Limit의 접근을 허용해 주세요. 키체인이 잠겨 있다면 먼저 잠금을 해제해 주세요."
        case .storageFailure(let status): "로그인 정보를 키체인에 저장하거나 읽지 못했습니다 (코드 \(status))."
        }
    }
}

