import SwiftUI

// MARK: - Color from Hex
extension Color {
    init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let components = NSColor(self).usingColorSpace(.sRGB)
        let r = Int((components?.redComponent ?? 0) * 255)
        let g = Int((components?.greenComponent ?? 0) * 255)
        let b = Int((components?.blueComponent ?? 0) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Record.FileType helpers
extension Record.FileType {
    var displayName: String {
        switch self {
        case .text: return "文本"
        case .web: return "网页"
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .log: return "日志"
        case .database: return "数据库"
        case .archive: return "压缩包"
        case .document: return "文档"
        case .file: return "文件"
        }
    }

    var icon: String {
        switch self {
        case .text: return "doc.plaintext"
        case .web: return "globe"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .log: return "terminal"
        case .database: return "cylinder"
        case .archive: return "archivebox"
        case .document: return "doc.richtext"
        case .file: return "doc"
        }
    }
}

// MARK: - Date Formatting
extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - String Preview
extension String {
    var preview: String {
        let stripped = self.replacingOccurrences(of: "#{1,6} ", with: "", options: .regularExpression)
        return String(stripped.prefix(150))
    }
}
