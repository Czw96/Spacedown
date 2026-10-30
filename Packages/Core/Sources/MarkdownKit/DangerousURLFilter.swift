import Foundation

/// 中和 `href` / `src` 等属性值里的危险 scheme。
///
/// `CMARK_OPT_UNSAFE` 打开后 cmark 不再净化链接，这一步就是链接层的防线。
///
/// 扫描对象是**渲染结果的字节**，不走 AST：裸 HTML 里的 `<a href="javascript:…">`
/// 不是语法树节点，走 AST 会整片漏掉。做法是把整个属性值换成页内锚点
/// （`javascript:alert(1)` → `#blocked-`）—— 冒号消失后它既跳不动也执行不了。
///
/// 属性值有三种写法（`"`、`'`、无引号），`=` 两侧还可能有空白，所以按「属性值起点」
/// 定位而不是按 `href="` 这类字面量匹配。属性名大小写不敏感，并要求左侧不是属性名
/// 字符，以免把 `data-href=` 当成 `href=`。
///
/// ⚠️ 这里只是纵深防御的一层：真正拦住脚本与远程加载的是文档外壳的 CSP
/// （`default-src 'none'; form-action 'none'`）。所以判定可以保守 —— 宁可多中和
/// 一个罕见写法，也不要漏掉一个。
enum DangerousURLFilter {

    /// 危险 scheme，小写。命中就把整个属性值换掉。
    private static let schemes: [[UInt8]] = ["javascript:", "vbscript:", "data:text/html"]
        .map { Array($0.utf8) }

    /// 承载 URL 的属性名（小写）。
    ///
    /// `xlink:href` 是 SVG 的老写法，`action` / `formaction` 是表单提交地址 ——
    /// 少了这几项，`<svg><a xlink:href="javascript:…">` 或 `<form action=…>` 会漏过去。
    private static let attributes: [(name: [UInt8], length: Int)] = [
        "href", "src", "srcset", "action", "formaction", "poster", "background", "cite",
        "xlink:href", "data",
    ].map { (Array($0.utf8), $0.utf8.count) }

    /// 属性值被替换成什么。只留一个页内锚点前缀，原值一个字节都不保留。
    private static let replacement = Data("#blocked-".utf8)

    /// 判断 scheme 时最多看这么多字节：真实 scheme 都在 20 字节以内。
    private static let probeLength = 64

    // MARK: - 入口

    /// 是否需要走重建路径：出现危险 scheme，或者出现 HTML 实体。
    ///
    /// 实体也要触发扫描，是因为浏览器会先解实体再交给 URL 解析器：
    /// `href="java&#115;cript:alert(1)"` 与 `javascript:` 等价，只看字面量会整片漏掉。
    /// 正常文档里没有实体时，代价就是一次字节扫描。
    static func needsNeutralizing(_ bytes: UnsafeBufferPointer<CChar>) -> Bool {
        schemes.contains { index(of: $0, in: bytes) != nil }
            || bytes.contains { $0 == CChar(UInt8(ascii: "&")) }
    }

    /// 重建字节流，只改动属性值，其余原样拷贝。
    static func neutralized(_ bytes: UnsafeBufferPointer<CChar>) -> Data {
        let raw = UnsafeRawBufferPointer(bytes)
        var output = Data()
        output.reserveCapacity(bytes.count)

        var copied = 0
        var index = 0
        while index < bytes.count {
            guard let value = attributeValue(in: bytes, at: index), isDangerous(bytes, value) else {
                index += 1
                continue
            }
            output.append(contentsOf: raw[copied..<value.lowerBound])
            output.append(replacement)
            index = value.upperBound
            copied = index
        }
        output.append(contentsOf: raw[copied..<bytes.count])
        return output
    }

    // MARK: - 定位

    /// `index` 处若是 URL 属性名的开头，返回属性值的字节区间（不含引号）。
    private static func attributeValue(in bytes: UnsafeBufferPointer<CChar>, at index: Int) -> Range<Int>? {
        // 左侧是属性名字符说明这只是更长名字的尾巴（`data-href` 里的 `href`）
        if index > 0, isAttributeNameByte(bytes[index - 1]) { return nil }

        guard let name = attributes.first(where: { matches($0.name, in: bytes, at: index) }) else { return nil }
        var cursor = skipSpaces(in: bytes, from: index + name.length)
        guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "=") else { return nil }

        cursor = skipSpaces(in: bytes, from: cursor + 1)
        guard cursor < bytes.count else { return nil }

        let quote = bytes[cursor]
        if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
            var end = cursor + 1
            while end < bytes.count, bytes[end] != quote { end += 1 }
            return cursor + 1 < end ? (cursor + 1)..<end : nil
        }
        var end = cursor
        while end < bytes.count, !isSpace(bytes[end]), bytes[end] != UInt8(ascii: ">") { end += 1 }
        return cursor < end ? cursor..<end : nil
    }

    /// 属性值是不是危险 scheme —— 先按 HTML 实体解码一遍再判断。
    private static func isDangerous(_ bytes: UnsafeBufferPointer<CChar>, _ value: Range<Int>) -> Bool {
        let probe = decodedPrefix(of: bytes, in: value)
        return schemes.contains { matchesPrefix($0, probe) }
    }

    // MARK: - 实体解码

    /// 取属性值开头的一小段，解掉 HTML 实体、去掉控制字符、统一小写。
    private static func decodedPrefix(of bytes: UnsafeBufferPointer<CChar>, in value: Range<Int>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(probeLength)

        var cursor = value.lowerBound
        while cursor < value.upperBound, out.count < probeLength {
            if bytes[cursor] == CChar(UInt8(ascii: "&")),
               let entity = entity(in: bytes, at: cursor, limit: value.upperBound) {
                append(entity.byte, to: &out)
                cursor = entity.end
                continue
            }
            append(UInt8(bitPattern: bytes[cursor]), to: &out)
            cursor += 1
        }

        var start = 0
        while start < out.count, out[start] <= 0x20 { start += 1 }
        return Array(out[start...])
    }

    /// 追加一个字节：丢掉制表/换行，字母折成小写。
    ///
    /// URL 解析器会删掉所有 ASCII 制表与换行，所以 `java\tscript:` 就是 `javascript:`；
    /// 这里跟着删，判据才与浏览器一致。
    private static func append(_ byte: UInt8, to out: inout [UInt8]) {
        if byte == 0x09 || byte == 0x0A || byte == 0x0D { return }
        if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") {
            out.append(byte + 32)
        } else {
            out.append(byte)
        }
    }

    /// 解析一个指向单个 ASCII 字符的实体：`&#115;` / `&#x73;` / `&colon;` 之类。
    ///
    /// 不认识、超出 ASCII、或没有以 `;` 收尾的都返回 nil —— 那就按原始字节处理。
    private static func entity(in bytes: UnsafeBufferPointer<CChar>, at index: Int, limit: Int) -> (byte: UInt8, end: Int)? {
        let named: [(name: [UInt8], byte: UInt8)] = [
            (Array("&colon;".utf8), UInt8(ascii: ":")),
            (Array("&Tab;".utf8), 0x09),
            (Array("&NewLine;".utf8), 0x0A),
            (Array("&amp;".utf8), UInt8(ascii: "&")),
        ]
        if let match = named.first(where: { matches($0.name, in: bytes, at: index) }) {
            return (match.byte, index + match.name.count)
        }

        guard matches([UInt8(ascii: "&"), UInt8(ascii: "#")], in: bytes, at: index) else { return nil }
        var cursor = index + 2
        var radix = 10
        if cursor < limit, UInt8(bitPattern: bytes[cursor]) | 0x20 == UInt8(ascii: "x") {
            radix = 16
            cursor += 1
        }

        var value = 0
        var digits = 0
        while cursor < limit, digits < 7 {
            let digit = digitValue(bytes[cursor], radix: radix)
            guard digit >= 0 else { break }
            value = value * radix + digit
            digits += 1
            cursor += 1
        }
        guard digits > 0, cursor < limit, bytes[cursor] == UInt8(ascii: ";"),
              value > 0, value < 0x80 else { return nil }
        return (UInt8(value), cursor + 1)
    }

    private static func digitValue(_ byte: CChar, radix: Int) -> Int {
        let value = Int(UInt8(bitPattern: byte))
        let lowered = Int(UInt8(bitPattern: byte) | 0x20)
        if radix == 16, lowered >= Int(UInt8(ascii: "a")), lowered <= Int(UInt8(ascii: "f")) {
            return lowered - Int(UInt8(ascii: "a")) + 10
        }
        if value >= Int(UInt8(ascii: "0")), value <= Int(UInt8(ascii: "9")) {
            return value - Int(UInt8(ascii: "0"))
        }
        return -1
    }

    // MARK: - 字节工具

    /// 小写 pattern 与字节流的前缀比较，大小写不敏感。
    private static func matches(_ pattern: [UInt8], in bytes: UnsafeBufferPointer<CChar>, at index: Int) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for offset in 0..<pattern.count
        where UInt8(bitPattern: bytes[index + offset]) | 0x20 != pattern[offset] {
            return false
        }
        return true
    }

    private static func matchesPrefix(_ pattern: [UInt8], _ bytes: [UInt8]) -> Bool {
        guard bytes.count >= pattern.count else { return false }
        for offset in 0..<pattern.count where bytes[offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// 大小写不敏感的 ASCII 子串查找。
    private static func index(of pattern: [UInt8], in bytes: UnsafeBufferPointer<CChar>) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        let last = bytes.count - pattern.count
        var index = 0
        while index <= last {
            if matches(pattern, in: bytes, at: index) { return index }
            index += 1
        }
        return nil
    }

    private static func skipSpaces(in bytes: UnsafeBufferPointer<CChar>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
        return index
    }

    private static func isSpace(_ byte: CChar) -> Bool {
        switch UInt8(bitPattern: byte) {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0C: return true
        default: return false
        }
    }

    /// 属性名字符。`-` / `_` / `:` 也算，因为自定义属性与命名空间属性常见。
    private static func isAttributeNameByte(_ byte: CChar) -> Bool {
        let value = UInt8(bitPattern: byte)
        let lowered = value | 0x20
        let isLetter = lowered >= UInt8(ascii: "a") && lowered <= UInt8(ascii: "z")
        let isDigit = value >= UInt8(ascii: "0") && value <= UInt8(ascii: "9")
        return isLetter || isDigit
            || value == UInt8(ascii: "-") || value == UInt8(ascii: "_") || value == UInt8(ascii: ":")
    }
}
