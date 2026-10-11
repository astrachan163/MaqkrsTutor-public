import SwiftUI

/// MaQkrs A1 palette. Use these hex values only.
/// Sky blue `#4888E8` and `#2F64C8`, leaf green `#3F9E40`, white `#FFFFFF`,
/// steel gray `#7880A0`, navy `#182048`. Cyan `#30D8F8` and gold `#F8D030`
/// are small accents.
/// Dark appearance accent text is A1 `accent.dark` `#88B0F8` in AccentColor.colorset.
/// That pair is 6.38:1 on `#2c2c2e`.
enum MaQkrsPalette {
    /// `#4888E8`
    static let skyBlue = Color(red: 72.0 / 255.0, green: 136.0 / 255.0, blue: 232.0 / 255.0)

    /// `#2F64C8`
    static let skyBlueDeep = Color(red: 47.0 / 255.0, green: 100.0 / 255.0, blue: 200.0 / 255.0)

    /// `#3F9E40`
    static let leafGreen = Color(red: 63.0 / 255.0, green: 158.0 / 255.0, blue: 64.0 / 255.0)

    /// `#FFFFFF`
    static let white = Color(red: 1.0, green: 1.0, blue: 1.0)

    /// `#7880A0`
    static let steelGray = Color(red: 120.0 / 255.0, green: 128.0 / 255.0, blue: 160.0 / 255.0)

    /// `#182048`
    static let navy = Color(red: 24.0 / 255.0, green: 32.0 / 255.0, blue: 72.0 / 255.0)

    /// `#30D8F8`
    static let cyan = Color(red: 48.0 / 255.0, green: 216.0 / 255.0, blue: 248.0 / 255.0)

    /// `#F8D030`
    static let gold = Color(red: 248.0 / 255.0, green: 208.0 / 255.0, blue: 48.0 / 255.0)
}
