import Foundation

/// 界面与提示文字只有中文和英文两种：系统首选语言是中文就用中文，否则用英文。
public enum L10n {
    public static let isChinese: Bool = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
}

/// `L("中文", "English")`
@inline(__always)
public func L(_ zh: String, _ en: String) -> String { L10n.isChinese ? zh : en }
