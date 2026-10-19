import Foundation

/// 中和 `href` / `src` 属性值里的危险 scheme。
///
/// `CMARK_OPT_UNSAFE` 打开后 cmark 不再净化链接，这一步就是链接层的防线。
///
/// 扫描对象是**渲染结果的字节**，不走 AST：裸 HTML 里的 `<a href="javascript:…">`
/// 不是语法树节点，走 AST 会整片漏掉。做法是把 scheme 换成页内锚点
/// （`javascript:alert(1)` → `#blocked-alert(1)`）—— 冒号消失后它既跳不动也执行不了。
///
/// 属性值有三种写法（`"`、`'`、无引号），`=` 两侧还可能有空白，所以按「属性值起点」
/// 定位而不是按 `href="` 这类字面量匹配。属性名大小写不敏感，并要求左侧不是属性名
/// 字符，以免把 `data-href=` 当成 `href=`。
enum DangerousURLFilter {

    private static let schemes: [[UInt8]] = ["javascript:", "vbscript:", "data:text/html"]
        .map { Array($0.utf8) }
    private static let attributes: [[UInt8]] = ["href", "src"].map { Array($0.utf8) }
    private static let replacement = Data("#blocked-".utf8)

    /// 渲染结果里是否出现过任何一个危险 scheme（大小写不敏感）。
    ///
    /// 正常文档恒为 false，所以调用方可以先用它挡掉重建路径。
    static func containsDangerousScheme(_ bytes: UnsafeBufferPointer<CChar>) -> Bool {
        schemes.contains { index(of: $0, in: bytes, from: 0) != nil }
    }

    /// 重建字节流，只改动属性值开头的那几个字节，其余原样拷贝。
    static func neutralized(_ bytes: UnsafeBufferPointer<CChar>) -> Data {
        let raw = UnsafeRawBufferPointer(bytes)
        var output = Data()
        output.reserveCapacity(bytes.count)

        var copied = 0
        var index = 0
        while index < bytes.count {
            if let valueStart = attributeValueStart(in: bytes, at: index),
               let schemeLength = schemeLength(in: bytes, at: valueStart) {
                output.append(contentsOf: raw[copied..<valueStart])
                output.append(replacement)
                index = valueStart + schemeLength
                copied = index
            } else {
                index += 1
            }
        }
        output.append(contentsOf: raw[copied..<bytes.count])
        return output
    }

    // MARK: - 定位

    /// `index` 处若是 `href=` / `src=`，返回属性值起点（已跳过空白与可选的开引号）。
    private static func attributeValueStart(in bytes: UnsafeBufferPointer<CChar>, at index: Int) -> Int? {
        if index > 0, isAttributeNameByte(bytes[index - 1]) { return nil }

        guard let name = attributes.first(where: { matches($0, in: bytes, at: index) }) else { return nil }
        var cursor = skipSpaces(in: bytes, from: index + name.count)
        guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "=") else { return nil }

        cursor = skipSpaces(in: bytes, from: cursor + 1)
        guard cursor < bytes.count else { return nil }
        if bytes[cursor] == UInt8(ascii: "\"") || bytes[cursor] == UInt8(ascii: "'") {
            cursor += 1
        }
        return cursor < bytes.count ? cursor : nil
    }

    /// `index` 处若以某个危险 scheme 开头，返回它的长度。
    private static func schemeLength(in bytes: UnsafeBufferPointer<CChar>, at index: Int) -> Int? {
        schemes.first { matches($0, in: bytes, at: index) }?.count
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

    /// 大小写不敏感的 ASCII 子串查找。
    private static func index(
        of pattern: [UInt8],
        in bytes: UnsafeBufferPointer<CChar>,
        from start: Int
    ) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        var index = max(0, start)
        let last = bytes.count - pattern.count
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
