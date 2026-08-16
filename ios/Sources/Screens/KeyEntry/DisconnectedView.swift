import SwiftUI

/// 資格情報が無い時の**1枚目**(2026-08-16、DESIGN §2.100 / `REQUIREMENTS.md` §9-5)。
///
/// ★此の画面の役割は「打たせる」ではなく「**名乗る**」。
/// Tom は同じ面に2回「論外」と言った(2026-08-11 / 2026-08-15)。1回目は本物の欠陥で、
/// その日に供給経路を引いた(§2.85 の `Provisioning`)。2回目に映っていたのは
/// **種を持たずに焼かれた束**で、画面はその事を一文字も名乗らず、ただ
/// 「Base URL と API Key を打て」とだけ出していた。名乗っていれば其の場で
/// 「焼き方が違う」と判り、4日は溶けなかった。
///
/// ★欄を**消さずに畳む**理由。机が鍵を回すと束に焼いた種は古くなり、鍵の無い電話は
/// 机に問い合わせる事も出来ない(鍵が API の唯一の資格)。手入力は構造上の最後の
/// 退避路で、消すと渡米先で戻る道が無くなる —— §9-3 で「一覧が読めない時に唯一
/// 押せる手」として矢印を残したのと同じ判断。畳む先を折り畳みではなく**別画面**に
/// したのは §9-4(1画面主義をやめる)の指示に合わせた為で、1枚目に欄が
/// **構造的に存在しない**事も同時に取れる。
struct DisconnectedView: View {
    let reason: AppState.DisconnectedReason
    let notice: SignOutNotice?
    let clients: KeyEntryClients
    let onPrimaryAction: (PrimaryAction) async -> Void
    let onSaved: (Credentials) -> Void

    /// 理由ごとに**1つだけ**出る主行動。無い理由も在る(押せる物が無い時に
    /// 押せる物を作らない —— 押しても何も起きないボタンは、故障を「押し方が悪い」に
    /// すり替える)。
    enum PrimaryAction: Equatable {
        /// 台帳の拒否を降ろして、焼き込まれた種でもう一度試す。
        case retryWithBundledSeed
        /// 金庫の読み直しだけ。状態は一つも変えない。
        case reloadStore

        var title: String {
            switch self {
            case .retryWithBundledSeed: return "Retry with the built-in key"
            case .reloadStore: return "Read again"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Text(Self.headline(for: reason, notice: notice))
                    .accessibilityIdentifier("disconnected.reason")
            }

            if let action = Self.primaryAction(for: reason) {
                Section {
                    Button {
                        Task { await onPrimaryAction(action) }
                    } label: {
                        Text(action.title)
                    }
                    .accessibilityIdentifier("disconnected.primaryAction")
                }
            }

            Section {
                NavigationLink {
                    KeyEntryView(clients: clients, notice: notice, onSaved: onSaved)
                } label: {
                    Text("Enter the key manually")
                }
                .accessibilityIdentifier("disconnected.manualEntry")
            } footer: {
                Text("This is a fallback. Rebuilding on the desk connects without typing anything.")
            }

            Section {
                EmptyView()
            } footer: {
                // 識別子の理由は `KeyEntryView` の版の行と同じ(監査 X2-7)。
                // 出ている事を主張するのが人の記憶だけ、という形にしない。
                Text(BuildInfo.line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("disconnected.buildInfo")
            }
        }
        .navigationTitle("Remote Mini")
    }

    /// 理由 → 文。view body から出してあるのは `KeyEntryView.sentence(for:)` と同じ理由で、
    /// body の中に書くと画面の規則なのにどの検査からも触れなくなるから。
    ///
    /// ★**電話から観測できない場所を書かない**(`KeyEntryView.sentence(for:)` と同じ制約)。
    /// 机側の鍵の path も、焼く台本の名前も書かない —— この app は其のどちらも一度も
    /// 見ていないので、机側で置き場が変われば静かに嘘になる。書けるのは
    /// 「机で焼き直す」という**行為**までで、其れは移動しない。
    static func headline(for reason: AppState.DisconnectedReason, notice: SignOutNotice?) -> String {
        switch reason {
        case .seedAbsent:
            return "This app was built without a destination. Rebuild it on the desk and it will connect without typing anything."
        case .seedRejected:
            return "The desk rejected the built-in key. If the key was restored on the desk, retry below. If it was rotated, rebuild the app on the desk."
        case .storeUnreadable:
            return "The phone's keychain could not be read. Unlock the phone and try reading again."
        case .keyRejected:
            // 断りの文は `KeyEntryView` が既に持っている。二重に書くと片方だけ腐るので借りる。
            return KeyEntryView.sentence(for: notice)
                ?? "The key that used to work was rejected by the server. Enter it again."
        case .unexplained:
            // ★「判らない」を尤もらしい理由に化けさせない。`build.sh` の `build_rev` が
            //   「判らなかった事を『汚れている』と言い換えない」為に持っている枠と同じ趣旨。
            return "The phone can't explain why it isn't connected. Rebuild on the desk, or enter the key manually."
        }
    }

    /// 理由 → 主行動。**押せる物が無い理由では `nil`**。
    ///
    /// ★此処が「行動が在るか」の唯一の出所。`RootView` は返って来た行動を
    /// `AppState` の口へ配るだけで、自分では判定しない —— 同じ判定を2箇所に置くと、
    /// 片方だけ腐って「ボタンは在るのに何も起きない」か「行動が在るのに出ない」になる。
    static func primaryAction(for reason: AppState.DisconnectedReason) -> PrimaryAction? {
        switch reason {
        case .seedRejected: return .retryWithBundledSeed
        case .storeUnreadable: return .reloadStore
        case .seedAbsent, .keyRejected, .unexplained: return nil
        }
    }
}
