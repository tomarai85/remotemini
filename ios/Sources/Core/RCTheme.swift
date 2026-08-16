import SwiftUI

/// 画面全体の意匠の正本(2026-08-17、Tom「UI が綺麗じゃない」)。
///
/// ★方針: iOS 標準の形(List / Form / NavigationStack)は崩さない —— 崩した自作
/// コンポーネントは「綺麗じゃない」の主因になりやすい。変えるのは**色の統一**で、
/// アプリアイコン(藍黒 × 青紫の ❯)と同じ系統の accent を全画面に通す。
/// 色は1箇所(此処)にだけ書く。散らすと画面ごとに微妙に違う紫が生える。
enum RCTheme {
    /// アイコンの ❯ の中間色(#6D5CFF)。ボタン・リンク・選択の tint。
    static let accent = Color(red: 0x6D / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)
    /// 持ち出しバッジ等の第二アクセント(#B05CFF 寄り)。
    static let violet = Color(red: 0xB0 / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)
}
