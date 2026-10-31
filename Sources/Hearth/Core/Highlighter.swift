import Foundation

/// Lightweight regex-based syntax highlighter. Not a parser — it aims for
/// "looks right" on the languages used in our repos at interactive speed.
enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, go, java, kotlin, javascript, typescript, python, ruby, rust, c, csharp, shell,
         json, yaml, toml, xml, html, css, markdown, sql, dockerfile, makefile, properties, plain

    static func detect(_ url: URL) -> SyntaxLanguage {
        let name = url.lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return .dockerfile }
        if name == "makefile" || name.hasSuffix(".mk") { return .makefile }
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "go": return .go
        case "java", "groovy", "gradle": return .java
        case "kt", "kts": return .kotlin
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "tsx", "mts": return .typescript
        case "py": return .python
        case "rb": return .ruby
        case "rs": return .rust
        case "c", "h", "cc", "cpp", "hpp", "m", "mm": return .c
        case "cs": return .csharp
        case "sh", "bash", "zsh", "fish", "envrc": return .shell
        case "json", "jsonc", "json5": return .json
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "xml", "plist", "pom", "xsd", "svg": return .xml
        case "html", "htm", "vue": return .html
        case "css", "scss", "less": return .css
        case "md", "markdown": return .markdown
        case "sql": return .sql
        case "properties", "env", "ini", "cfg", "conf": return .properties
        default: return .plain
        }
    }
}

enum TokenKind: Sendable {
    case keyword, type, string, number, comment, attribute, function, key, tag, punctuation, heading
}

struct Token: Sendable {
    let range: NSRange
    let kind: TokenKind
}

enum Highlighter {
    private struct Rule {
        let regex: NSRegularExpression
        let kind: TokenKind
        let group: Int
    }

    private static func r(_ pattern: String, _ kind: TokenKind, group: Int = 0,
                          options: NSRegularExpression.Options = []) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), kind: kind, group: group)
    }

    private static func keywords(_ words: String) -> Rule {
        r("\\b(?:" + words.split(separator: " ").joined(separator: "|") + ")\\b", .keyword)
    }

    private static let number = r(#"\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, .number)
    private static let dq = r(#""(?:[^"\\\n]|\\.)*""#, .string)
    private static let sq = r(#"'(?:[^'\\\n]|\\.)*'"#, .string)
    private static let bt = r(#"`(?:[^`\\]|\\.)*`"#, .string)
    private static let tripleDQ = r(#""""[\s\S]*?""""#, .string)
    private static let lineSlash = r(#"//[^\n]*"#, .comment)
    private static let lineHash = r(#"#[^\n]*"#, .comment)
    private static let lineDash = r(#"--[^\n]*"#, .comment)
    private static let block = r(#"/\*[\s\S]*?\*/"#, .comment)
    private static let typeName = r(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type)
    private static let call = r(#"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?=\()"#, .function, group: 1)
    private static let annotation = r(#"@[A-Za-z_][A-Za-z0-9_.]*"#, .attribute)

    /// Rules are applied in order; later rules do not override earlier ones
    /// (so keywords inside strings/comments stay string/comment colored).
    private static func rules(for lang: SyntaxLanguage) -> [Rule] {
        switch lang {
        case .swift:
            return [block, lineSlash, tripleDQ, dq, annotation, r(#"#[a-zA-Z]+"#, .attribute),
                    keywords("let var func if else guard return for in while repeat switch case default break continue struct class enum protocol extension import init deinit self Self throws throw try catch do async await actor some any where as is nil true false private fileprivate internal public open static final override mutating nonmutating lazy weak unowned inout typealias associatedtype defer get set willSet didSet subscript"),
                    call, typeName, number]
        case .go:
            return [block, lineSlash, bt, dq, sq,
                    keywords("package import func return if else for range switch case default break continue go defer select chan map struct interface type var const fallthrough goto nil true false iota make new len cap append panic recover error string int int64 int32 uint byte rune bool float64 any"),
                    call, typeName, number]
        case .java, .kotlin, .csharp:
            return [block, lineSlash, tripleDQ, dq, sq, annotation,
                    keywords("package import class interface enum record extends implements public private protected static final abstract void return if else for while do switch case default break continue new this super try catch finally throw throws null true false var val fun object companion data sealed override open when is as in out suspend lateinit init synchronized volatile transient instanceof assert yield using namespace readonly async await get set"),
                    call, typeName, number]
        case .javascript, .typescript:
            return [block, lineSlash, bt, dq, sq, annotation,
                    keywords("import export from default function return if else for while do switch case break continue new this class extends super try catch finally throw const let var async await yield typeof instanceof in of null undefined true false interface type enum implements public private protected readonly static as keyof declare namespace void never unknown any"),
                    call, typeName, number]
        case .python:
            return [tripleDQ, r(#"'''[\s\S]*?'''"#, .string), lineHash, dq, sq, annotation,
                    keywords("def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield global nonlocal None True False async await self assert del"),
                    call, typeName, number]
        case .ruby:
            return [lineHash, dq, sq,
                    keywords("def class module end if elsif else unless while until for in do return yield begin rescue ensure raise self nil true false and or not require attr_accessor attr_reader private protected public then case when"),
                    r(#":[a-z_][A-Za-z0-9_]*"#, .attribute), call, typeName, number]
        case .rust:
            return [block, lineSlash, dq, r(#"#\[[^\]]*\]"#, .attribute),
                    keywords("fn let mut pub mod use crate super self Self struct enum impl trait for in if else match loop while return break continue as ref move async await dyn where type const static unsafe extern true false Some None Ok Err"),
                    call, typeName, number]
        case .c:
            return [block, lineSlash, dq, sq, r(#"^\s*#\s*\w+"#, .attribute, options: .anchorsMatchLines),
                    keywords("int char float double void long short unsigned signed const static struct union enum typedef return if else for while do switch case default break continue sizeof extern inline auto register volatile goto NULL true false bool class public private protected template typename namespace new delete this virtual override nullptr"),
                    call, typeName, number]
        case .shell, .dockerfile, .makefile:
            var rules = [lineHash, dq, sq, r(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, .attribute),
                         keywords("if then else elif fi for in do done while until case esac function return local export set unset source echo exit")]
            if lang == .dockerfile {
                rules.insert(r(#"^\s*(?:FROM|RUN|CMD|COPY|ADD|ENV|ARG|WORKDIR|EXPOSE|ENTRYPOINT|USER|LABEL|VOLUME|HEALTHCHECK)\b"#,
                               .keyword, options: [.anchorsMatchLines, .caseInsensitive]), at: 1)
            }
            if lang == .makefile {
                rules.insert(r(#"^[A-Za-z0-9_.\-/ ]+(?=:)"#, .function, options: .anchorsMatchLines), at: 1)
            }
            return rules + [number]
        case .json:
            return [r(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, .key), dq, keywords("true false null"), number]
        case .yaml:
            return [lineHash, r(#"^(\s*-?\s*)([A-Za-z0-9_.\-/"']+)(?=\s*:)"#, .key, group: 2, options: .anchorsMatchLines),
                    dq, sq, keywords("true false null yes no on off"), r(#"[&*][A-Za-z0-9_\-]+"#, .attribute), number]
        case .toml, .properties:
            return [lineHash, r(#"^\s*;[^\n]*"#, .comment, options: .anchorsMatchLines),
                    r(#"^\s*\[[^\]\n]+\]"#, .type, options: .anchorsMatchLines),
                    r(#"^\s*([A-Za-z0-9_.\-]+)(?=\s*[=:])"#, .key, group: 1, options: .anchorsMatchLines),
                    dq, sq, keywords("true false"), number]
        case .xml, .html:
            return [r(#"<!--[\s\S]*?-->"#, .comment), dq, sq,
                    r(#"</?([A-Za-z][A-Za-z0-9:_\-.]*)"#, .tag, group: 1),
                    r(#"\b([A-Za-z_:][A-Za-z0-9_:\-.]*)(?==)"#, .attribute, group: 1)]
        case .css:
            return [block, dq, sq, r(#"([A-Za-z\-]+)(?=\s*:)"#, .key, group: 1),
                    r(#"[.#][A-Za-z_\-][A-Za-z0-9_\-]*"#, .type), r(#"#[0-9a-fA-F]{3,8}\b"#, .number), number]
        case .markdown:
            return [r(#"```[\s\S]*?```"#, .string), r(#"`[^`\n]+`"#, .string),
                    r(#"^#{1,6} [^\n]*"#, .heading, options: .anchorsMatchLines),
                    r(#"\[[^\]\n]+\]\([^)\n]+\)"#, .function), r(#"(\*\*|__)[^*\n]+\1"#, .keyword),
                    r(#"^\s*(?:[-*+]|\d+\.)\s"#, .punctuation, options: .anchorsMatchLines)]
        case .sql:
            return [block, lineDash, sq, dq,
                    r("\\b(?:SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|ALTER|DROP|INDEX|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|AND|OR|NOT|NULL|IS|IN|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|PRIMARY|KEY|FOREIGN|REFERENCES|DISTINCT|UNION|CASE|WHEN|THEN|ELSE|END|EXISTS|DEFAULT|CONSTRAINT|UNIQUE|BEGIN|COMMIT|ROLLBACK)\\b",
                      .keyword, options: .caseInsensitive), number]
        case .plain:
            return []
        }
    }

    private static let cache = NSCache<NSString, RulesBox>()
    private final class RulesBox { let rules: [Rule]; init(_ r: [Rule]) { rules = r } }

    static let maxLength = 400_000

    static func tokens(in text: String, language: SyntaxLanguage) -> [Token] {
        let ns = text as NSString
        guard ns.length <= maxLength, language != .plain else { return [] }
        let key = language.rawValue as NSString
        let rules: [Rule]
        if let box = cache.object(forKey: key) { rules = box.rules } else {
            rules = Self.rules(for: language)
            cache.setObject(RulesBox(rules), forKey: key)
        }
        var taken = IndexSet()
        var result: [Token] = []
        let full = NSRange(location: 0, length: ns.length)
        for rule in rules {
            for m in rule.regex.matches(in: text, range: full) {
                let range = m.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let span = range.location..<(range.location + range.length)
                if taken.intersects(integersIn: span) { continue }
                taken.insert(integersIn: span)
                result.append(Token(range: range, kind: rule.kind))
            }
        }
        return result
    }
}
