import XCTest
@testable import RemoteMini

/// 電話から新しい会話を始めた時の**答えの読み分け**。
///
/// ★測る中心は「成功を成功と読む」ではなく **「机が断った理由を潰さない」**。
///   此の経路は 3 通りの断り方が在り、どれも人の次の一手が違う:
///     作業場所が無い  → 其の会話からは始められない(別の会話を選ぶ)
///     机が window を作れない → 机の側の異常(tmux が落ちている等)
///     鍵が違う        → 設定を見る
///   全部「失敗しました」に丸めると、電話を持っている人は何をすればよいか判らない。
final class NewSessionOutcomeTests: XCTestCase {

    func test_202は開始として読む() {
        XCTAssertEqual(NewSessionOutcome.from(status: 202, code: nil), .started)
    }

    func test_409は作業場所が無いとして読む() {
        // 机の route は `cwd_unknown` / `cwd_gone` の 2 つを 409 で返す。
        // 電話から見ると次の一手は同じ(其の会話からは始められない)ので 1 つに畳む。
        XCTAssertEqual(NewSessionOutcome.from(status: 409, code: "no_cwd"), .noWorkingDirectory)
    }

    func test_tmuxの失敗を机の異常として読む() {
        XCTAssertEqual(NewSessionOutcome.from(status: 502, code: "tmux_failed"), .deskRefused)
    }

    func test_401は鍵の問題として読む() {
        XCTAssertEqual(NewSessionOutcome.from(status: 401, code: nil), .unauthorized)
    }

    func test_知らない失敗を机の異常に丸めない() {
        // 500 で code が無い = 何が起きたか判らない。`deskRefused`(= tmux が作れない)と
        // 言い切ると、人は tmux を見に行って空振りする。判らない物は「届かない」へ。
        XCTAssertEqual(NewSessionOutcome.from(status: 500, code: nil), .unreachable)
    }

    func test_どの答えも人の次の一手を含む一文を持つ() {
        // 「失敗しました」で終わる文が 1 つでも在ると、其の経路は電話の上で行き止まりになる。
        for outcome in [NewSessionOutcome.started, .noWorkingDirectory,
                        .deskRefused, .unauthorized, .unreachable] {
            XCTAssertFalse(outcome.text.isEmpty, "\(outcome) に文が無い")
        }
        // ★「始めました」で止めない —— 一覧に出るまで間が在る事を言っていなければ、
        //   押した人は効かなかったと読んで二度押しする。
        XCTAssertTrue(NewSessionOutcome.started.text.lowercased().contains("shortly")
                      || NewSessionOutcome.started.text.lowercased().contains("list"),
                      "開始の文が「一覧に出るまで間が在る」を言っていない")
    }
}
