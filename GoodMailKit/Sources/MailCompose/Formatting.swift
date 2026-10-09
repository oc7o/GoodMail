import CoreText
import Foundation
import SwiftUI

/// The formatting a message body can carry, applied to the composer's `TextEditor`.
///
/// Everything outside `Scope` (background colours, kerning, line height, Genmoji, AppKit and UIKit attributes) is
/// ignored by the editor and dropped by `constrain(_:)`; the value constraints squash what is left into what the
/// HTML writer can express. The editor applies the definition to what the user types and pastes, but not to
/// programmatic writes, so text from anywhere else (Writing Tools, App Intents, a loaded draft) goes through
/// `constrain(_:)` or `MailBodyNormalizer` first.
public struct MailBodyFormatting: AttributedTextFormattingDefinition {
    public struct Scope: AttributeScope {
        public let font: AttributeScopes.SwiftUIAttributes.FontAttribute
        public let foregroundColor: AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
        public let underlineStyle: AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
        public let strikethroughStyle: AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute
        public let link: AttributeScopes.FoundationAttributes.LinkAttribute
        public let alignment: AttributeScopes.CoreTextAttributes.TextAlignmentAttribute
        public let writingDirection: AttributeScopes.FoundationAttributes.WritingDirectionAttribute
    }

    public init() {}

    public var body: some AttributedTextFormattingDefinition<Scope> {
        MailFontConstraint()
        ValueConstraint(for: \.foregroundColor, values: Set(MailPalette.colors.map(\.color) + [nil]), default: nil)
        MailUnderlineConstraint()
        ValueConstraint(for: \.underlineStyle, values: [nil, .single], default: .single)
        MailStrikethroughConstraint()
        ValueConstraint(for: \.strikethroughStyle, values: [nil, .single], default: .single)
        MailLinkConstraint()
    }
}

/// SwiftUI attributes named by type where AppKit and UIKit have attributes of the same name and the value alone
/// (`.single`, `nil`, an untyped tuple) doesn't tell the compiler which one is meant.
typealias UnderlineAttribute = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
typealias FontAttribute = AttributeScopes.SwiftUIAttributes.FontAttribute
typealias StrikethroughAttribute = AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute

/// The text colours the composer offers. Text without a colour follows the reader's default, which keeps dark
/// mode working on both ends; free colours would not.
public enum MailPalette {
    public struct Entry: Sendable, Hashable {
        public let name: String
        public let color: Color
        /// What recipients get: dark enough to read on white, the background most mail clients use.
        public let css: String
    }

    public static let colors: [Entry] = [
        Entry(name: "Red", color: .red, css: "#d70015"),
        Entry(name: "Orange", color: .orange, css: "#c93400"),
        Entry(name: "Green", color: .green, css: "#248a3d"),
        Entry(name: "Blue", color: .blue, css: "#0040dd"),
        Entry(name: "Purple", color: .purple, css: "#8944ab"),
        Entry(name: "Gray", color: .gray, css: "#6e6e73"),
    ]

    public static func entry(for color: Color?) -> Entry? {
        guard let color else { return nil }
        return colors.first { $0.color == color }
    }

    public static func entry(css: String) -> Entry? {
        let value = css.trimmingCharacters(in: .whitespaces).lowercased()
        return colors.first { $0.css == value }
    }
}

/// A font reduced to what mail can carry: bold, italic, monospace and a coarse relative size.
public struct MailFontStyle: Hashable, Sendable {
    public enum Size: Int, CaseIterable, Sendable {
        case small, normal, large, huge

        var scale: CGFloat { [0.8, 1, 1.3, 1.7][rawValue] }
        /// The CSS `font-size` the HTML writer uses; normal text has none.
        var css: String? { ["80%", nil, "130%", "170%"][rawValue] }
        public var title: String { ["Small", "Normal", "Large", "Huge"][rawValue] }

        static func nearest(to ratio: Double) -> Size {
            allCases.min { abs($0.scale - ratio) < abs($1.scale - ratio) } ?? .normal
        }
    }

    public var isBold: Bool
    public var isItalic: Bool
    public var isMonospaced: Bool
    public var size: Size

    public init(isBold: Bool = false, isItalic: Bool = false, isMonospaced: Bool = false, size: Size = .normal) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.isMonospaced = isMonospaced
        self.size = size
    }

    /// Resolution needs a context; the default environment is enough to read traits and relative size, and it
    /// works off the main actor, so the HTML writer and App Intents can use it too.
    public static let context = EnvironmentValues().fontResolutionContext

    /// The size is read relative to the context's default font, so it comes out the same at every Dynamic Type
    /// size for the fonts `font` produces.
    public init(_ font: Font?, in context: Font.Context = MailFontStyle.context) {
        self.init()
        guard let font else { return }
        let resolved = font.resolve(in: context)
        isBold = resolved.isBold
        isItalic = resolved.isItalic
        isMonospaced = resolved.isMonospaced
        size = Size.nearest(to: resolved.pointSize / Font.default.resolve(in: context).pointSize)
    }

    /// The canonical font for this style; nil for plain text, so the environment's font applies. Sizes scale the
    /// default font rather than naming a point size, so they follow Dynamic Type with the rest of the text.
    public var font: Font? {
        guard self != MailFontStyle() else { return nil }
        var font = Font.default
        if isMonospaced { font = font.monospaced() }
        if size != .normal { font = font.scaled(by: size.scale) }
        if isBold { font = font.bold() }
        if isItalic { font = font.italic() }
        return font
    }
}

/// Pasted text arrives with arbitrary platform fonts; keep only the traits mail can express.
public struct MailFontConstraint: AttributedTextValueConstraint {
    public typealias Scope = MailBodyFormatting.Scope
    public typealias AttributeKey = AttributeScopes.SwiftUIAttributes.FontAttribute

    public init() {}

    public func constrain(_ container: inout Attributes) {
        guard let font = container.font else { return }
        container.font = MailFontStyle(font).font
    }
}

/// Double, dotted or coloured lines are still lines: they become the plain line mail can carry. On its own, the
/// value constraint after this one would remove them, since it maps values outside its set to nil.
public struct MailUnderlineConstraint: AttributedTextValueConstraint {
    public typealias Scope = MailBodyFormatting.Scope
    public typealias AttributeKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute

    public init() {}

    public func constrain(_ container: inout Attributes) {
        if container.underlineStyle != nil { container.underlineStyle = .single }
    }
}

public struct MailStrikethroughConstraint: AttributedTextValueConstraint {
    public typealias Scope = MailBodyFormatting.Scope
    public typealias AttributeKey = AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute

    public init() {}

    public func constrain(_ container: inout Attributes) {
        if container.strikethroughStyle != nil { container.strikethroughStyle = .single }
    }
}

/// Only links a recipient can safely follow.
public struct MailLinkConstraint: AttributedTextValueConstraint {
    public typealias Scope = MailBodyFormatting.Scope
    public typealias AttributeKey = AttributeScopes.FoundationAttributes.LinkAttribute

    static let schemes: Set<String> = ["http", "https", "mailto", "tel"]

    public init() {}

    public func constrain(_ container: inout Attributes) {
        guard let url = container.link else { return }
        if !Self.schemes.contains(url.scheme?.lowercased() ?? "") {
            container.link = nil
        }
    }
}

/// What the formatting controls show for the current selection.
public struct FormattingState: Equatable, Sendable {
    public var isBold = false
    public var isItalic = false
    public var isUnderlined = false
    public var isStruckThrough = false
    public var isMonospaced = false
    /// Every selected paragraph is a list item, bulleted or numbered.
    public var isList = false
    /// Every selected paragraph is a numbered list item.
    public var isNumberedList = false
    public var size = MailFontStyle.Size.normal
    public var color: MailPalette.Entry?
    public var link: URL?

    public init() {}
}
