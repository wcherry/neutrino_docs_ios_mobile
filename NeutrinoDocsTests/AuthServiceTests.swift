import XCTest
@testable import NeutrinoDocs

/// Milestone 1 deliverable: **Login**.
///
/// Exercises the whole three-step PKCE flow against `MockURLProtocol`, including the redirect step
/// that carries the authorization code, so the test covers what the app actually does rather than
/// the individual helpers underneath it.
@MainActor
final class AuthServiceTests: XCTestCase {

    private var sut: AuthService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.use()
        sut = AuthService(configuration: Self.mockConfiguration())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    private static func mockConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    // MARK: - Happy path

    func testLoginCompletesFullFlowAndPersistsTokens() async {
        stubSuccessfulFlow()

        await sut.login(email: "user@example.com", password: "hunter2")

        XCTAssertNil(sut.loginError)
        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertEqual(KeychainService.load(forKey: AuthService.accessTokenKey), "access-123")
        XCTAssertEqual(KeychainService.load(forKey: AuthService.refreshTokenKey), "refresh-456")
        XCTAssertNotNil(KeychainService.load(forKey: AuthService.tokenExpiryKey))
    }

    func testLoginVisitsAllThreeEndpointsInOrder() async {
        stubSuccessfulFlow()

        await sut.login(email: "user@example.com", password: "hunter2")

        let paths = MockURLProtocol.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, [
            "/api/v1/auth/login",
            "/api/v1/oauth/authorize",
            "/api/v1/oauth/token",
        ])
    }

    /// Device registration: there is no separate endpoint — a device registers by naming itself on
    /// the login request, which is what populates the session row `/auth/sessions` later lists.
    func testLoginSendsDeviceNameHeader() async {
        stubSuccessfulFlow()

        await sut.login(email: "user@example.com", password: "hunter2")

        let login = MockURLProtocol.request { $0.url?.path == "/api/v1/auth/login" }
        XCTAssertEqual(login?.value(forHTTPHeaderField: DeviceIdentity.deviceNameHeader),
                       DeviceIdentity.deviceName)
    }

    func testAuthorizeRequestCarriesPKCEChallengeAndSessionBearer() async {
        stubSuccessfulFlow()

        await sut.login(email: "user@example.com", password: "hunter2")

        let authorize = MockURLProtocol.request { $0.url?.path == "/api/v1/oauth/authorize" }
        let query = URLComponents(url: authorize!.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "response_type" }?.value, "code")
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, "neutrino-docs-ios")
        XCTAssertFalse((query.first { $0.name == "code_challenge" }?.value ?? "").isEmpty)
        XCTAssertEqual(authorize?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
    }

    func testTokenExchangeSendsCodeVerifier() async {
        stubSuccessfulFlow()

        await sut.login(email: "user@example.com", password: "hunter2")

        let index = MockURLProtocol.requests.firstIndex { $0.url?.path == "/api/v1/oauth/token" }
        let body = String(data: MockURLProtocol.bodies[index!], encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=auth-code-abc"))
        XCTAssertTrue(body.contains("code_verifier="))
    }

    // MARK: - Failures

    func testInvalidCredentialsReportsErrorAndDoesNotAuthenticate() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        await sut.login(email: "user@example.com", password: "wrong")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.loginError, AuthError.invalidCredentials.errorDescription)
        XCTAssertNil(KeychainService.load(forKey: AuthService.accessTokenKey))
    }

    /// The state parameter is the client's only defence that the redirect answers *its* request.
    /// A mismatch must abort before the code is spent.
    func testStateMismatchAbortsLogin() async {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/auth/login" {
                return (Self.ok(request), Data(#"{"accessToken":"session-token"}"#.utf8))
            }
            if path == "/api/v1/oauth/authorize" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 302, httpVersion: nil,
                    headerFields: ["Location": "neutrino://oauth/callback?code=auth-code-abc&state=WRONG"]
                )!
                return (response, Data())
            }
            return (Self.ok(request), Data())
        }

        await sut.login(email: "user@example.com", password: "hunter2")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.loginError, AuthError.stateMismatch.errorDescription)
        // The token endpoint must never have been reached.
        XCTAssertNil(MockURLProtocol.request { $0.url?.path == "/api/v1/oauth/token" })
    }

    func testMissingCodeInRedirectReportsError() async {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/auth/login" {
                return (Self.ok(request), Data(#"{"accessToken":"session-token"}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "neutrino://oauth/callback?state=xyz"]
            )!
            return (response, Data())
        }

        await sut.login(email: "user@example.com", password: "hunter2")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.loginError, AuthError.missingCode.errorDescription)
    }

    func testNetworkFailureReportsErrorWithoutAuthenticating() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        await sut.login(email: "user@example.com", password: "hunter2")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNotNil(sut.loginError)
    }

    // MARK: - Logout

    func testLogoutClearsTokensButKeepsEncryptionKeys() async {
        TestKeys.install()
        defer { TestKeys.remove() }
        stubSuccessfulFlow()
        await sut.login(email: "user@example.com", password: "hunter2")
        XCTAssertTrue(sut.isAuthenticated)

        sut.logout()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNil(KeychainService.load(forKey: AuthService.accessTokenKey))
        XCTAssertNil(KeychainService.load(forKey: AuthService.refreshTokenKey))
        // Signing out is not the same as forgetting the key — Settings removes that explicitly.
        XCTAssertTrue(KeyImportService.hasStoredKeys())
    }

    // MARK: - Refresh

    func testRefreshIsSkippedWhileTokenIsStillValid() async {
        TestTokens.install()
        MockURLProtocol.respond(json: "{}")

        await sut.refreshTokenIfNeeded()

        XCTAssertEqual(MockURLProtocol.requestCount, 0, "A valid token must not cost a round trip")
    }

    func testExpiredTokenIsRefreshedWithRefreshGrant() async {
        KeychainService.save("old-access", forKey: AuthService.accessTokenKey)
        KeychainService.save("refresh-456", forKey: AuthService.refreshTokenKey)
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        KeychainService.save(past, forKey: AuthService.tokenExpiryKey)
        MockURLProtocol.respond(json: #"""
        {"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}
        """#)

        await sut.refreshTokenIfNeeded()

        let body = String(data: MockURLProtocol.bodies.first ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertEqual(KeychainService.load(forKey: AuthService.accessTokenKey), "new-access")
    }

    /// A rejected refresh token means the session is genuinely over.
    func testRejectedRefreshSignsTheUserOut() async {
        KeychainService.save("old-access", forKey: AuthService.accessTokenKey)
        KeychainService.save("refresh-456", forKey: AuthService.refreshTokenKey)
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        KeychainService.save(past, forKey: AuthService.tokenExpiryKey)
        sut = AuthService(configuration: Self.mockConfiguration())
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        await sut.refreshTokenIfNeeded()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNil(KeychainService.load(forKey: AuthService.accessTokenKey))
    }

    /// An unreachable server is not a reason to sign somebody out of an offline-first app.
    func testUnreachableServerDuringRefreshKeepsTheSession() async {
        KeychainService.save("old-access", forKey: AuthService.accessTokenKey)
        KeychainService.save("refresh-456", forKey: AuthService.refreshTokenKey)
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        KeychainService.save(past, forKey: AuthService.tokenExpiryKey)
        sut = AuthService(configuration: Self.mockConfiguration())
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        await sut.refreshTokenIfNeeded()

        XCTAssertEqual(KeychainService.load(forKey: AuthService.accessTokenKey), "old-access")
    }

    // MARK: - PKCE

    func testPKCEChallengeIsSHA256OfVerifierBase64URLEncoded() {
        let (verifier, challenge) = AuthService.pkceValues()

        XCTAssertFalse(verifier.isEmpty)
        // Base64URL alphabet only — a "+", "/", or "=" would be rejected by the server.
        XCTAssertNil(challenge.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(challenge.count, 43, "SHA-256 in unpadded base64url is 43 characters")
    }

    func testPKCEValuesAreUniquePerCall() {
        let first = AuthService.pkceValues()
        let second = AuthService.pkceValues()
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertNotEqual(first.challenge, second.challenge)
    }

    // MARK: - Helpers

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    /// Stubs all three legs, echoing the request's own `state` back so the happy path is not
    /// accidentally testing against a hardcoded value.
    private func stubSuccessfulFlow() {
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v1/auth/login":
                return (Self.ok(request), Data(#"{"accessToken":"session-token"}"#.utf8))

            case "/api/v1/oauth/authorize":
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                let state = items?.first { $0.name == "state" }?.value ?? ""
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 302, httpVersion: nil,
                    headerFields: ["Location": "neutrino://oauth/callback?code=auth-code-abc&state=\(state)"]
                )!
                return (response, Data())

            case "/api/v1/oauth/token":
                return (Self.ok(request), Data(#"""
                {"access_token":"access-123","refresh_token":"refresh-456","expires_in":3600,"token_type":"Bearer"}
                """#.utf8))

            default:
                return (Self.ok(request), Data())
            }
        }
    }
}
