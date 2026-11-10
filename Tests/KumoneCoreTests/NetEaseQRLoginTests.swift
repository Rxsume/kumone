import Foundation
import Testing
@testable import KumoneCore

/// Fixture tests for the restored NetEase QR login (`MusicAPI.qrKey` /
/// `qrCheck` / `qrLoginURL` and the `QRStatus` poll mapping). Offline
/// only: every payload below is a synthetic fixture — no real unikey,
/// nickname or credential appears here, and nothing touches the network.
/// The URL assertion is host-agnostic on purpose: `Upstream.hosts` is
/// process-wide state other suites reconfigure, so only the path and
/// the `codekey` query are asserted here.
@Suite("NetEase QR login")
struct NetEaseQRLoginTests {

    private func decodeCheck(_ json: String) throws -> MusicAPI.QRCheckResponse {
        try JSONDecoder().decode(MusicAPI.QRCheckResponse.self, from: Data(json.utf8))
    }

    @Test func qrKeyResponseDecodesUnikey() throws {
        let response = try JSONDecoder().decode(
            MusicAPI.QRKeyResponse.self,
            from: Data("{\"code\":200,\"unikey\":\"test-unikey-0000\"}".utf8))
        #expect(response.code == 200)
        #expect(response.unikey == "test-unikey-0000")
    }

    @Test(arguments: [
        (800, "{\"code\":800,\"message\":\"二维码已过期\"}", nil as String?),
        (801, "{\"code\":801}", nil as String?),
        (802, "{\"code\":802,\"nickname\":\"测试用户\",\"avatarUrl\":\"https://example.com/a.jpg\"}", "测试用户" as String?),
        (803, "{\"code\":803,\"message\":\"授权登录成功\",\"nickname\":\"测试用户\",\"avatarUrl\":\"https://example.com/a.jpg\"}", "测试用户" as String?),
    ])
    func qrCheckResponseDecodes(code: Int, json: String, nickname: String?) throws {
        let check = try decodeCheck(json)
        #expect(check.code == code)
        #expect(check.nickname == nickname)
    }

    @Test func qrCheckResponseToleratesMissingOptionals() throws {
        let check = try decodeCheck("{\"code\":801}")
        #expect(check.message == nil)
        #expect(check.nickname == nil)
        #expect(check.avatarUrl == nil)
    }

    @Test(arguments: [
        (800, MusicAPI.QRStatus.expired),
        (801, MusicAPI.QRStatus.waiting),
        (803, MusicAPI.QRStatus.success),
    ])
    func qrStatusMapsWaitingAndTerminalCodes(code: Int, expected: MusicAPI.QRStatus) throws {
        let check = try decodeCheck("{\"code\":\(code)}")
        #expect(MusicAPI.qrStatus(from: check) == expected)
    }

    @Test func qrStatusKeepsScannedNickname() throws {
        let check = try decodeCheck("{\"code\":802,\"nickname\":\"测试用户\"}")
        #expect(MusicAPI.qrStatus(from: check) == .scanned(nickname: "测试用户"))
    }

    @Test func qrStatusKeepsScannedNicknameWhenMissing() throws {
        let check = try decodeCheck("{\"code\":802}")
        #expect(MusicAPI.qrStatus(from: check) == .scanned(nickname: ""))
    }

    @Test func qrStatusLeavesUnknownCodesUnknown() throws {
        let check = try decodeCheck("{\"code\":999}")
        #expect(MusicAPI.qrStatus(from: check) == .unknown(code: 999))
    }

    @Test func qrLoginURLCarriesCodeKey() {
        let url = MusicAPI.qrLoginURL(unikey: "test-unikey-0000")
        #expect(url?.hasPrefix("https://") == true)
        #expect(url?.contains("/login?codekey=test-unikey-0000") == true)
    }
}
