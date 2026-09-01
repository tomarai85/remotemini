import SwiftUI

/// 画面全体の意匠の正本(2026-08-17、Tom「UI が綺麗じゃない」→ 同日「全体的に完璧じゃない」)。
///
/// ★2回目の指摘で方針を改めた: 標準部品への tint だけでは「設定画面」の形が残る。
/// 変えるのは色でなく**面の系**(地・カード・縁・角丸・文字の階層)。ただし趣味の
/// 収束は具体物の選択でしか起きないので、同じレイアウトに雰囲気違いの variant を
/// 3方向持ち、実機のスクショで Tom に選ばせる。選ばれた物が既定に昇格する。
///
/// ★variant の切替は DEBUG 限定の環境変数(`RC_THEME_VARIANT`)。Release には
/// 綴りごと存在しない(`RC_UI_FIXTURE` と同じ判断 — 出荷物に実験の口を残さない)。
/// 色は此処にだけ書く。散らすと画面ごとに微妙に違う紫が生える。
enum RCTheme {
    enum Variant: String {
        /// A: Claude 公式アプリ系の暖色ダーク(墨色の地 + テラコッタ)。
        case claudeWarm = "claude"
        /// B: ライトミニマル(白カード + 藍紫 = 今のアイコンと同系)。
        case lightMinimal = "light"
        /// C: グラファイトダーク(青黒の地 + 藍紫)。
        case graphite = "graphite"
        /// D: Liquid Glass・ダーク(Tom 指名 2026-08-17「Glass っぽい感じ」)。
        /// 地は深い藍黒 + 柔らかい光彩、カードは iOS 26 の glassEffect(旧 OS は material)。
        case glassDark = "glassdark"
        /// E: Liquid Glass・ライト。
        case glassLight = "glasslight"
        /// F: Glass 徹底(2026-08-29、Tom「(イマイチなのは)正直全部」「Liquid glass の方が重要」)。
        /// D と同じ藍系のまま、光彩・透け・丸み・縁を一段深くする。
        case glassMax = "glassmax"
        /// G: Glass + 端末の血(同日「ちょっと Linux 感出せると嬉しい」)。
        /// ガラスは D 相当のまま、全画面 monospaced + 差し色を蛍光緑 + 第二色を teal に。
        case glassTerm = "glassterm"
        /// H: D の磨き上げ(対照)。構造は D のまま、縁・光彩・角丸の調整だけでどこまで
        /// 上がるかを測る — F/G が勝ったとしても、差が構造由来か調整由来かを分離する為に要る。
        case glassPolish = "glasspolish"
        /// J: 全面ガラス・暗(2026-08-29、Tom「全部ベースが同じだから変わらない。全部 Glass がいい」)。
        /// F の反省 = 調味料の増減では閾値に届かない。地を鮮やかな多色に、縁にキャッチライト、
        /// 光彩を主役に。ガラスが硝子に見えるのは**下に透ける色**が有る時だけ(RCBackdrop の注釈)。
        case glassFull = "glassfull"
        /// K: 全面ガラス・明。Liquid Glass が一番映えるのは明るい地(Apple のデモが明るい理由)。
        /// Tom は 08-17 に暗を選んだが、全面ガラス化で前提が変わるので明も1枚出して測る。
        case glassBright = "glassbright"
    }

    static let variant: Variant = resolveVariant()

    private static func resolveVariant() -> Variant {
        #if DEBUG
        // 診断行(RootView の `root flow:` と同じ流儀)。2026-08-29、sim の env 経由で
        // variant が一度も効いていない事が判明した時に入れた — 「届いていない」と
        // 「届いたが読めない」を console で見分ける為の計器。DEBUG 限定。
        if let raw = ProcessInfo.processInfo.environment["RC_THEME_VARIANT"] {
            if let v = Variant(rawValue: raw) {
                print("theme variant:\(raw)")
                return v
            }
            print("theme variant unknown:\(raw)")
        } else {
            print("theme variant env:absent")
        }
        #endif
        // 既定 = graphite(平らな暗い面)。2026-09-01 Tom 裁定で glassFull から差し替え。
        //
        // ★何故 降りたか(Tom 逐語「UI が汚い」「無駄だねキーボードしかガラスっぽくないし」):
        //   ガラスは面・縁・屈折・光彩が**常に同時に**効くので、引き算ができない。
        //   実際 2026-09-01 に枠を外そうとしたが、縁を描いているのは `RCCard` ではなく
        //   iOS 26 の `glassEffect` 自身で、SwiftUI からは消せなかった。
        //   ★更に本質的な指摘: ガラスが**ガラスに見えるのは後ろが動く時だけ**。
        //     動かない一覧の上では屈折する物が無く、濁った灰色の板にしかならない。
        //     キーボード(後ろを内容が流れる)だけが本当にガラスに見えていた。
        //   2026-08-29 の「全部 Glass」は Tom 自身の裁定だったが、実物を見て撤回された。
        return .graphite
    }

    /// ボタン・リンク・選択の tint。
    static let accent: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .lightMinimal: return Color(red: 0x6D / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)
        case .graphite: return Color(red: 0x7C / 255.0, green: 0x6C / 255.0, blue: 0xFF / 255.0)
        case .glassDark: return Color(red: 0x8B / 255.0, green: 0x7C / 255.0, blue: 0xFF / 255.0)
        case .glassLight: return Color(red: 0x6D / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)
        case .glassMax: return Color(red: 0x8B / 255.0, green: 0x7C / 255.0, blue: 0xFF / 255.0)
        case .glassTerm: return Color(red: 0x5C / 255.0, green: 0xE8 / 255.0, blue: 0x7B / 255.0)
        case .glassPolish: return Color(red: 0x95 / 255.0, green: 0x87 / 255.0, blue: 0xFF / 255.0)
        case .glassFull: return Color(red: 0x8B / 255.0, green: 0x7C / 255.0, blue: 0xFF / 255.0)
        case .glassBright: return Color(red: 0x5B / 255.0, green: 0x4A / 255.0, blue: 0xF5 / 255.0)
        }
    }()

    /// 承認の危険度(2026-08-26)。**押せる物は変えない** —— 読む前に押すのを止めるだけの色。
    /// 直値を画面へ置かず此処に集める理由は他のトークンと同じ: 5案の切替が効かなくなる。
    static let danger: Color = {
        switch variant {
        case .claudeWarm:   return Color(red: 0xF2 / 255.0, green: 0x7A / 255.0, blue: 0x6E / 255.0)
        case .lightMinimal: return Color(red: 0xC4 / 255.0, green: 0x28 / 255.0, blue: 0x20 / 255.0)
        case .graphite:     return Color(red: 0xFF / 255.0, green: 0x7B / 255.0, blue: 0x72 / 255.0)
        case .glassDark:    return Color(red: 0xFF / 255.0, green: 0x8A / 255.0, blue: 0x80 / 255.0)
        case .glassLight:   return Color(red: 0xC0 / 255.0, green: 0x2A / 255.0, blue: 0x22 / 255.0)
        case .glassMax, .glassPolish, .glassFull: return Color(red: 0xFF / 255.0, green: 0x8A / 255.0, blue: 0x80 / 255.0)
        case .glassTerm:    return Color(red: 0xFF / 255.0, green: 0x7B / 255.0, blue: 0x72 / 255.0)
        case .glassBright:  return Color(red: 0xC0 / 255.0, green: 0x2A / 255.0, blue: 0x22 / 255.0)
        }
    }()

    /// 外へ出る操作(戻せるが他人から見える)。danger より弱い段。
    static let caution: Color = {
        switch variant {
        case .claudeWarm:   return Color(red: 0xE8 / 255.0, green: 0xB3 / 255.0, blue: 0x39 / 255.0)
        case .lightMinimal: return Color(red: 0x9A / 255.0, green: 0x6B / 255.0, blue: 0x00 / 255.0)
        case .graphite:     return Color(red: 0xE3 / 255.0, green: 0xB3 / 255.0, blue: 0x41 / 255.0)
        case .glassDark:    return Color(red: 0xF5 / 255.0, green: 0xC2 / 255.0, blue: 0x4E / 255.0)
        case .glassLight:   return Color(red: 0x8F / 255.0, green: 0x63 / 255.0, blue: 0x00 / 255.0)
        case .glassMax, .glassPolish, .glassFull: return Color(red: 0xF5 / 255.0, green: 0xC2 / 255.0, blue: 0x4E / 255.0)
        case .glassTerm:    return Color(red: 0xD9 / 255.0, green: 0xC9 / 255.0, blue: 0x4A / 255.0)
        case .glassBright:  return Color(red: 0x8F / 255.0, green: 0x63 / 255.0, blue: 0x00 / 255.0)
        }
    }()

    /// 持ち出しバッジ等の第二アクセント。
    static let violet: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0xB8 / 255.0, green: 0xA7 / 255.0, blue: 0xEA / 255.0)
        case .lightMinimal: return Color(red: 0xB0 / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)
        case .graphite: return Color(red: 0xB7 / 255.0, green: 0x8C / 255.0, blue: 0xFF / 255.0)
        case .glassDark: return Color(red: 0xC0 / 255.0, green: 0x9A / 255.0, blue: 0xFF / 255.0)
        case .glassLight: return Color(red: 0xA8 / 255.0, green: 0x6B / 255.0, blue: 0xFF / 255.0)
        case .glassMax, .glassPolish, .glassFull: return Color(red: 0xC0 / 255.0, green: 0x9A / 255.0, blue: 0xFF / 255.0)
        case .glassTerm: return Color(red: 0x64 / 255.0, green: 0xD8 / 255.0, blue: 0xCB / 255.0)
        case .glassBright: return Color(red: 0xA8 / 255.0, green: 0x6B / 255.0, blue: 0xFF / 255.0)
        }
    }()

    /// 画面の地(glass では光彩の下に敷く基調色)。
    static let background: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0x26 / 255.0, green: 0x24 / 255.0, blue: 0x20 / 255.0)
        case .lightMinimal: return Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0)
        case .graphite: return Color(red: 0x0F / 255.0, green: 0x11 / 255.0, blue: 0x15 / 255.0)
        case .glassDark: return Color(red: 0x0B / 255.0, green: 0x0C / 255.0, blue: 0x14 / 255.0)
        case .glassLight: return Color(red: 0xF1 / 255.0, green: 0xF0 / 255.0, blue: 0xF8 / 255.0)
        case .glassMax: return Color(red: 0x07 / 255.0, green: 0x08 / 255.0, blue: 0x10 / 255.0)
        case .glassTerm: return Color(red: 0x06 / 255.0, green: 0x0B / 255.0, blue: 0x09 / 255.0)
        case .glassPolish: return Color(red: 0x0B / 255.0, green: 0x0C / 255.0, blue: 0x14 / 255.0)
        case .glassFull: return Color(red: 0x15 / 255.0, green: 0x17 / 255.0, blue: 0x34 / 255.0)
        case .glassBright: return Color(red: 0xE7 / 255.0, green: 0xE9 / 255.0, blue: 0xF8 / 255.0)
        }
    }()

    /// カードの面(glass では旧 OS の fallback tint にだけ使う)。
    static let surface: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0x32 / 255.0, green: 0x30 / 255.0, blue: 0x2B / 255.0)
        case .lightMinimal: return .white
        case .graphite: return Color(red: 0x1A / 255.0, green: 0x1E / 255.0, blue: 0x26 / 255.0)
        case .glassDark: return Color.white.opacity(0.06)
        case .glassLight: return Color.white.opacity(0.55)
        case .glassMax: return Color.white.opacity(0.10)
        case .glassTerm: return Color.white.opacity(0.07)
        case .glassPolish: return Color.white.opacity(0.08)
        case .glassFull: return Color.white.opacity(0.14)
        case .glassBright: return Color.white.opacity(0.50)
        }
    }()

    /// 面の 1 段上(自分の発言の泡など、カードより手前に在る物)。
    ///
    /// ★2026-09-01 新設。理由は「色が気に入らない」ではなく**系統の混在**:
    ///   平らな variant の側だけ `Color(.systemGray5)` / `.systemGray6` / `.bar` ——
    ///   Apple のシステム灰 = **中立灰(R≒G≒B)**を使っていた。此の配色の本体は
    ///   青寄り(graphite の面 #1A1E26 は B が R より 12 高い)なので、
    ///   一画面に灰色の系統が 2 つ並ぶ。実測: 泡 (44,44,46) / 面 (26,30,38)。
    ///   ★人は「青い灰」と「中立の灰」を色名では区別しないが、**隣に並ぶと**
    ///     片方が汚れて見える。「洗練されていない」の実体は大体これ。
    static let surfaceElevated: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0x3E / 255.0, green: 0x3B / 255.0, blue: 0x35 / 255.0)
        case .lightMinimal: return Color(red: 0xE9 / 255.0, green: 0xE9 / 255.0, blue: 0xEE / 255.0)
        case .graphite: return Color(red: 0x26 / 255.0, green: 0x2C / 255.0, blue: 0x38 / 255.0)
        // glass の系では自分の泡は accent の淡い面なので此処は使われない。
        // それでも定義するのは、後から平らな variant を足した時に穴が開かない為。
        case .glassDark: return Color.white.opacity(0.12)
        case .glassLight: return Color.white.opacity(0.70)
        case .glassMax: return Color.white.opacity(0.16)
        case .glassTerm: return Color.white.opacity(0.13)
        case .glassPolish: return Color.white.opacity(0.14)
        case .glassFull: return Color.white.opacity(0.20)
        case .glassBright: return Color.white.opacity(0.65)
        }
    }()

    /// カードの縁(暗い variant はこれが影の代わり)。
    static let surfaceStroke: Color = {
        switch variant {
        case .claudeWarm: return Color.white.opacity(0.07)
        case .lightMinimal: return Color.black.opacity(0.06)
        // ★2026-09-01: 枠を消した(0.08 → 0)。カードが縦に並ぶ時、薄い枠は
        //   「箱の羅列」に見える。面の明度差(地 #0F1115 / 面 #1A1E26)だけで
        //   充分に分かれるので、線は要らない。
        case .graphite: return Color.clear
        case .glassDark: return Color.white.opacity(0.12)
        case .glassLight: return Color.white.opacity(0.65)
        case .glassMax: return Color.white.opacity(0.16)
        case .glassTerm: return Color(red: 0x5C / 255.0, green: 0xE8 / 255.0, blue: 0x7B / 255.0).opacity(0.22)
        case .glassPolish: return Color.white.opacity(0.18)
        case .glassFull: return Color.white.opacity(0.28)
        case .glassBright: return Color.white.opacity(0.85)
        }
    }()

    /// カードの影(ライト系のみ。暗い地に影は描かれず費用だけ掛かる)。
    static let cardShadowOpacity: Double = {
        switch variant {
        case .lightMinimal: return 0.05
        case .glassLight: return 0.07
        case .glassBright: return 0.08
        case .claudeWarm, .graphite, .glassDark, .glassMax, .glassTerm, .glassPolish, .glassFull: return 0
        }
    }()

    /// 系全体の明暗。nil にしない — OS 設定で片側だけ検証されないまま出るのを防ぐ。
    static let colorScheme: ColorScheme = {
        switch variant {
        case .claudeWarm, .graphite, .glassDark, .glassMax, .glassTerm, .glassPolish, .glassFull: return .dark
        case .lightMinimal, .glassLight, .glassBright: return .light
        }
    }()

    /// Liquid Glass の面か(カードの描き方が fill から material/glass に替わる)。
    static let usesGlass: Bool = {
        switch variant {
        case .glassDark, .glassLight, .glassMax, .glassTerm, .glassPolish, .glassFull, .glassBright: return true
        case .claudeWarm, .lightMinimal, .graphite: return false
        }
    }()

    /// カードの角丸(glass はひと回り丸く — Liquid Glass の意匠は丸みが強い。
    /// glassTerm だけ角張らせる = 端末の血)。
    static let cardRadius: CGFloat = {
        switch variant {
        case .glassMax: return 24
        case .glassFull, .glassBright: return 26
        case .glassPolish: return 22
        case .glassTerm: return 16
        case .glassDark, .glassLight: return 20
        case .claudeWarm, .lightMinimal, .graphite: return 14
        }
    }()

    /// 地の光彩の強さ(RCBackdrop が読む)。glass でない variant では 0(描かれない)。
    /// D=0.32 / E=0.38 は旧実装(colorScheme 分岐)と同値 — 既存2案の見た目を変えない。
    static let glowStrength: Double = {
        switch variant {
        case .glassMax: return 0.50
        // ★2026-09-01: 0.80 → 0.34。Tom「UI が汚い」。
        //   0.80 は 400-500pt の玉 4 個が全面に効いていて、其の上に半透明の面を
        //   重ねるので**濁る**。色が意味を持たず、只 全部を紫にしていた。
        //   薄くすると、色は「地の気配」に戻り、意味を持つのは状態の色だけになる。
        case .glassFull: return 0.34
        case .glassBright: return 0.55
        case .glassPolish: return 0.40
        case .glassTerm: return 0.30
        case .glassDark: return 0.32
        case .glassLight: return 0.38
        case .claudeWarm, .lightMinimal, .graphite: return 0
        }
    }()

    /// 全画面の書体の系。glassTerm だけ monospaced(端末の血)。nil = 標準。
    /// 当て所は RemoteMiniApp の根の1箇所(散らさない — 色と同じ理由)。
    static let fontDesign: Font.Design? = variant == .glassTerm ? .monospaced : nil

    /// 全面ガラス系か(J/K)。地の光彩が5玉の多色になり、カードの縁にキャッチライトが載る。
    /// F(glassMax)との違いは度合いでなく**層の数** — 調味料の増減は「変わらない」と裁定済み
    /// (Tom 2026-08-29「全部ベースが同じだから変わらない」)。
    static let glassRich: Bool = variant == .glassFull || variant == .glassBright
}

/// 画面の地。glass では柔らかい光彩を敷く — 平色の上の glass は屈折する物が無く
/// ただの灰色に見えるので、地の光彩が glass を glass に見せる当の部品。
struct RCBackdrop: View {
    // ★玉は必ず overlay に置く(2026-08-29 実測)。ZStack の「子」として描くと、固定 frame の
    //   circle(420-460pt)が親 ZStack の幅を画面より広げ、同居する content が引き伸ばされて
    //   行が画面外へはみ出す(ListView は RCBackdrop を ZStack の子として持つ)。overlay は
    //   土台のサイズに一切寄与しないので、玉が何個・何 pt でもレイアウトに触れない。
    var body: some View {
        RCTheme.background
            .overlay {
                orbs
            }
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var orbs: some View {
        ZStack {
            if RCTheme.glassRich {
                // 全面ガラス(J/K): 同族3+1色(indigo/violet/cyan 系)に絞る。5色に散らすと
                // 虹になって安く見える(2026-08-29 design pass、ui-ux-pro-max の禁則
                // 「rainbow gradients を避ける」)。ガラスは下に透ける色が有って初めて硝子に
                // 見えるので、ここが J/K の主役。玉の色はトークンでなく此処の直値 —
                // 「地の絵」は1枚の絵として調整する物で、意味色(accent/danger)と混ぜない。
                let glow: Double = RCTheme.glowStrength
                Circle().fill(Color(red: 0x6D / 255.0, green: 0x5C / 255.0, blue: 1.0).opacity(glow))
                    .frame(width: 500, height: 500).blur(radius: 110)
                    .offset(x: -140, y: -240)
                Circle().fill(Color(red: 0xA0 / 255.0, green: 0x5C / 255.0, blue: 1.0).opacity(glow * 0.8))
                    .frame(width: 440, height: 440).blur(radius: 105)
                    .offset(x: 170, y: 40)
                Circle().fill(Color(red: 0x3C / 255.0, green: 0xC8 / 255.0, blue: 1.0).opacity(glow * 0.6))
                    .frame(width: 460, height: 460).blur(radius: 110)
                    .offset(x: -60, y: 420)
                Circle().fill(Color(red: 0x8B / 255.0, green: 0x7C / 255.0, blue: 1.0).opacity(glow * 0.5))
                    .frame(width: 400, height: 400).blur(radius: 110)
                    .offset(x: 150, y: 700)
                // 題と状態バーの裏を静める幕。文字は騒がしい地の上に置くと安く見える —
                // 幕は variant 自身の基調色なので暗(J)でも明(K)でも正しく働く。
                //
                // ★2026-08-31。以前は `.top → .center` で、**画面の下半分に幕が無かった**。
                //   転写と入力欄は其処に居るので、光彩の玉の上に小さな字が素で乗っていた。
                //   実測(監査): 玉の上で `.tertiary` 1.8:1 / `.secondary` 3.2:1 /
                //   警告の `.orange` 2.9:1 —— **壊れている時に読む文字が一番読めない**状態。
                //   全高へ伸ばし、下端にも床を作る。玉は残るので意匠は変わらない。
                LinearGradient(colors: [RCTheme.background.opacity(0.9), RCTheme.background.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)
            } else if RCTheme.usesGlass {
                let glow: Double = RCTheme.glowStrength
                Circle().fill(RCTheme.accent.opacity(glow))
                    .frame(width: 420, height: 420).blur(radius: 110)
                    .offset(x: -130, y: -220)
                Circle().fill(RCTheme.violet.opacity(glow * 0.9))
                    .frame(width: 380, height: 380).blur(radius: 100)
                    .offset(x: 170, y: 60)
                Circle().fill(Color.cyan.opacity(glow * 0.45))
                    .frame(width: 380, height: 380).blur(radius: 120)
                    .offset(x: -40, y: 430)
            }
        }
    }
}

extension View {
    /// Form / List を意匠の地に載せる(標準の不透明な地を退けて RCBackdrop を敷く)。
    /// 行の面は標準のまま — HIG の Liquid Glass は glass を**操作の層**に限り、
    /// 内容の面まで透かさない。ここでも glass はカード・帯・ボタンの側に置く。
    func rcThemedSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(RCBackdrop())
    }
}

/// チップ(バッジ・機体名乗り等)の面。glass 系はガラス仕立て(material + 色の縁)、
/// それ以外は従来の淡い塗り。色チップの「ベタ塗り 0.12」はガラスの上では板に見える —
/// チップも透けて初めて系が揃う(2026-08-29 design pass)。
struct RCChip: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        // ★2026-09-01: 面と縁を落とし、**淡い塗りだけ**にした。Tom「UI が汚い」。
        //   material + 色の縁は、1 行に 2 個 並ぶと「小さい箱の羅列」に見える ——
        //   一覧の行は既にカードの面に乗っているので、其の上で更に面を重ねると
        //   層が 3 枚になり、何が容器で何が中身か読めなくなる。
        //   色は文字が持ち、面は気配だけ持つ。
        content.background(tint.opacity(0.14), in: Capsule())
    }
}

/// カード1枚の面。glass 系は iOS 26 の Liquid Glass(旧 OS は material に落ちる)、
/// それ以外は塗り + 縁。`emphasized` = choice 行(机側の Enter が承認/課金になり得る
/// 唯一の状態)だけ橙で名指しする。
extension RCTheme {
    /// composer の入力欄の**面**。
    ///
    /// ★2026-09-01 に token 化した。理由は色ではなく**構造**:
    ///   2026-08-29 に Tom が「黒い箱が洗練されていない」と言った時、私は直しを
    ///   `if RCTheme.usesGlass` の**ガラス側の枝にだけ**入れ、else 側は
    ///   `.textFieldStyle(.roundedBorder)` のまま残した。既定が graphite に
    ///   替わった瞬間、其の直しは 1 行も効かなくなり、実測の画で入力欄の中が
    ///   **(0,0,0) の純黒** —— 配色の中で唯一の純黒 —— に戻っていた。
    ///   同じ形を上限告知でも踏んでいる(`usesGlass` の else 側に在って電話で
    ///   一度も描かれていなかった)。★**直しが枝の片側にしか無い状態を作らない**
    ///   為に、枝を消して差を token 1 個へ畳んだ。呼ぶ側は 1 本道になる。
    /// composer の**帯**の面(転写と composer を分ける層)。
    ///
    /// ★2026-09-01 に token 化した。理由は色ではなく**検査が成立するかどうか**:
    ///   平らな側は `Rectangle().fill(.bar)` という**この画面で一意な綴り**だった。
    ///   `bar-is-composer-only.test.mjs` は其の一意性の上に立っていて、
    ///   「帯の材質が `loadEarlierFooter` に敷かれていない」を**バイトで**測る
    ///   (XCUITest は色も材質も読めないので、この repo に他の測り方が無い)。
    ///   私が `.bar` を汎用の `RCTheme.surface` へ替えた時、綴りがカード・チップと
    ///   衝突して**門の前提ごと壊れた**(検査 2 本が赤)。
    ///   ★門を緩めるのではなく、**帯に固有の名前を返す**のが正しい直し方。
    ///     不変条件(帯は composer だけの物)は 1 ミリも動いていない。
    static var composerBarFill: AnyShapeStyle {
        usesGlass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(surface)
    }

    static var composerFieldFill: AnyShapeStyle {
        usesGlass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(background)
    }
}

struct RCCard: ViewModifier {
    var emphasized = false

    func body(content: Content) -> some View {
        if RCTheme.usesGlass {
            // ★2026-09-01: 縁のキャッチライトを外した。Tom「UI が汚い」。
            //   硝子の面・縁の光・枠線の **3 重**が同時に効いていて、
            //   カードが縦に並ぶと灰色の箱の羅列に見える(= 開発ツールの見た目)。
            //   面だけ残し、分離は**余白**に持たせる。装飾を足すのではなく引く。
            glassBody(content)
        } else {
            content
                // ★2026-09-01: 強調でも**面は他の行と同じ**にした。
                //   以前は橙 12% を敷いていたが、地が炭色(#0F1115)なので橙は色として
                //   立たず**茶色い汚れ**に見える(実測の画 `shots-clean/flat-list-normal.png`
                //   の 1 枚目)。硝子の側で同じ理由から 0.30 → 0.10 に落としており、
                //   平らな面では 0 まで行くのが正しかった。
                //   ★「今 Tom を待っている」は 橙の点・橙の文字・橙の枠が既に 3 度
                //     言っている。面まで染めるのは 4 度目で、しかも一番濁る言い方。
                .background(
                    RoundedRectangle(cornerRadius: RCTheme.cardRadius, style: .continuous)
                        .fill(RCTheme.surface)
                        .shadow(color: .black.opacity(RCTheme.cardShadowOpacity), radius: 6, y: 2)
                )
                .overlay {
                    if emphasized {
                        // 枠は残す —— 枠が**この 1 枚だけ**に付くから意味が出る。
                        // 全部に付いていた頃(2026-09-01 朝まで)は箱の羅列だった。
                        RoundedRectangle(cornerRadius: RCTheme.cardRadius, style: .continuous)
                            .stroke(Color.orange.opacity(0.55), lineWidth: 1)
                    }
                }
        }
    }

    @ViewBuilder
    private func glassBody(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // ★2026-09-01: 強調の塗りを 0.30 → 0.10。Tom「UI が汚い」。
            //   0.30 は面が**茶色く濁る**(硝子の上の橙は色として立たず、汚れに見える)。
            //   「今 Tom を待っている」を伝えるのは既に橙の点と橙の文字がやっている ——
            //   面まで染めるのは 3 度言っている事になり、しかも一番濁る言い方だった。
            content.glassEffect(
                emphasized ? .regular.tint(Color.orange.opacity(0.10)) : .regular,
                in: .rect(cornerRadius: RCTheme.cardRadius)
            )
        } else {
            // iOS 17-25: 素の material。屈折は無いが「透ける面」までは同じ。
            content
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: RCTheme.cardRadius, style: .continuous))
                // ★強調(要返信)の時だけ縁を出す。常時 出すと「全部が主役」になり、
                //   本当に見てほしい 1 枚が沈む。
                .overlay {
                    if emphasized {
                        RoundedRectangle(cornerRadius: RCTheme.cardRadius, style: .continuous)
                            .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                    }
                }
        }
    }
}
