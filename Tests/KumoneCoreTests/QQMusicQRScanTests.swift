import Foundation
import Testing
@testable import KumoneCore

/// Fixture tests for the QQ QR-login poll mapping (`ptqrlogin`
/// `ptuiCB(...)` responses -> `QQMusicAuth.PollOutcome`).
/// Offline only: the fixtures are canned callback strings in the two
/// shapes `parsePTUI` supports (`code,url,'0',msg,nick` and
/// `code,'0',url,msg,nick`); nothing here touches the network, and no
/// real credential is involved.
@Suite("QQ QR login poll-state mapping tests")
struct QQMusicQRScanTests {
    // MARK: - parsePTUI fixtures

    @Test func parsesWaitingCallback() {
        let parsed = QQMusicAuth.parsePTUI("ptuiCB('66','0','0','...','')")
        #expect(parsed?.code == "66")
        #expect(parsed?.url == nil)
        #expect(parsed?.nickname == "")
    }

    @Test func parsesScannedCallbackWithNickname() {
        let parsed = QQMusicAuth.parsePTUI("ptuiCB('67','0','0','...','测试昵称')")
        #expect(parsed?.code == "67")
        #expect(parsed?.nickname == "测试昵称")
    }

    @Test func parsesExpiredCallbacks() {
        #expect(QQMusicAuth.parsePTUI("ptuiCB('65','0','0','...','')")?.code == "65")
        #expect(QQMusicAuth.parsePTUI("ptuiCB('68','0','0','...','')")?.code == "68")
    }

    @Test func parsesSuccessCallbackWithURLInThirdSlot() {
        let parsed = QQMusicAuth.parsePTUI(
            "ptuiCB('0','0','https://ptlogin2.qq.com/check_sig?ptqrtoken=123&uin=456','...','测试昵称')"
        )
        #expect(parsed?.code == "0")
        #expect(parsed?.url == "https://ptlogin2.qq.com/check_sig?ptqrtoken=123&uin=456")
        #expect(parsed?.nickname == "测试昵称")
    }

    @Test func parsesSuccessCallbackWithURLInSecondSlot() {
        let parsed = QQMusicAuth.parsePTUI(
            "ptuiCB('0','https://ptlogin2.qq.com/check_sig?ptqrtoken=123','0','...','昵称')"
        )
        #expect(parsed?.code == "0")
        #expect(parsed?.url == "https://ptlogin2.qq.com/check_sig?ptqrtoken=123")
    }

    @Test func parsesSuccessCallbackWithoutURL() {
        let parsed = QQMusicAuth.parsePTUI("ptuiCB('0','0','0','...','昵称')")
        #expect(parsed?.code == "0")
        #expect(parsed?.url == nil)
    }

    @Test func rejectsUnparseableCallbacks() {
        #expect(QQMusicAuth.parsePTUI("garbage") == nil)
        #expect(QQMusicAuth.parsePTUI("") == nil)
        #expect(QQMusicAuth.parsePTUI("ptuiCB('66')") == nil)
    }

    // MARK: - pollOutcome mapping

    @Test func mapsWaitingCode() {
        #expect(QQMusicAuth.pollOutcome(for: (code: "66", url: nil, nickname: "")) == .waiting)
    }

    @Test func mapsScannedCode() {
        #expect(QQMusicAuth.pollOutcome(for: (code: "67", url: nil, nickname: "测试昵称")) == .scanned)
    }

    @Test func mapsExpiredCodes() {
        #expect(QQMusicAuth.pollOutcome(for: (code: "65", url: nil, nickname: "")) == .expired)
        #expect(QQMusicAuth.pollOutcome(for: (code: "68", url: nil, nickname: "")) == .expired)
    }

    @Test func mapsSuccessCodeToAuthorize() {
        let outcome = QQMusicAuth.pollOutcome(
            for: (code: "0", url: "https://ptlogin2.qq.com/check_sig?ptqrtoken=123", nickname: "测试昵称")
        )
        #expect(outcome == .authorize(url: "https://ptlogin2.qq.com/check_sig?ptqrtoken=123", nickname: "测试昵称"))
    }

    @Test func mapsSuccessCodeWithoutURLToError() {
        let outcome = QQMusicAuth.pollOutcome(for: (code: "0", url: nil, nickname: "昵称"))
        #expect(outcome == .error("登录成功但凭证获取失败"))
    }

    @Test func mapsUnknownCodeToWaiting() {
        // Beans parity: an unknown code keeps polling until the server
        // expires the code, instead of failing the login outright.
        #expect(QQMusicAuth.pollOutcome(for: (code: "100", url: nil, nickname: "")) == .waiting)
    }

    @Test func mapsFixtureCallbacksEndToEnd() {
        let waiting = QQMusicAuth.parsePTUI("ptuiCB('66','0','0','...','')")
        #expect(waiting.map { QQMusicAuth.pollOutcome(for: $0) } == .waiting)
        let scanned = QQMusicAuth.parsePTUI("ptuiCB('67','0','0','...','测试昵称')")
        #expect(scanned.map { QQMusicAuth.pollOutcome(for: $0) } == .scanned)
        let expired = QQMusicAuth.parsePTUI("ptuiCB('65','0','0','...','')")
        #expect(expired.map { QQMusicAuth.pollOutcome(for: $0) } == .expired)
        let success = QQMusicAuth.parsePTUI(
            "ptuiCB('0','0','https://ptlogin2.qq.com/check_sig?ptqrtoken=123','...','测试昵称')"
        )
        #expect(success.map { QQMusicAuth.pollOutcome(for: $0) }
            == .authorize(url: "https://ptlogin2.qq.com/check_sig?ptqrtoken=123", nickname: "测试昵称"))
    }
}
