#!/usr/bin/env swift
import Foundation
import CryptoKit

// 更新包签名工具（Ed25519，等价于 Sparkle 用的 EdDSA）。
//
// 为什么需要它：本 App 没有 Developer ID，更新包无法用 Apple 的代码签名背书。
// 只校 sha256 等于没校 —— 那个值也是 GitHub 算的，账号被盗就一起被换掉。
// 自签一对密钥之后，没有私钥就签不出能被老版本接受的更新。
//
// 用法：
//   swift scripts/sign_update.swift --generate
//       生成 ~/.spacedown-signing/update-signing.key（600），并把公钥打印出来，
//       粘贴进 Spacedown/Support/UpdateSigning.swift 的 publicKeyBase64。
//   swift scripts/sign_update.swift --sign <file>
//       在同目录写出 <file>.sig（base64 的单行签名）。
//
// ⚠️ 私钥不在仓库里，也**不要**放进仓库。丢了就只能换一对新密钥，
//    而老版本里烘焙的是旧公钥 —— 那种情况下只能让用户手动下载一次新版。

let keyDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".spacedown-signing")
let keyURL = keyDir.appendingPathComponent("update-signing.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
    exit(1)
}

func generate() {
    let key = Curve25519.Signing.PrivateKey()
    let raw = key.rawRepresentation
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

    do {
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        try Data((raw.base64EncodedString() + "\n").utf8).write(to: keyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    } catch {
        fail("写私钥失败：\(error.localizedDescription)")
    }

    print("私钥已写入 \(keyURL.path)（权限 600，勿入库、勿外传）")
    print("")
    print("把下面这行粘进 Spacedown/Support/UpdateSigning.swift：")
    print("    static let publicKeyBase64 = \"\(publicKey)\"")
}

func sign(_ path: String) {
    guard FileManager.default.fileExists(atPath: keyURL.path) else {
        fail("私钥不存在：\(keyURL.path)，先跑 --generate")
    }
    guard let raw = Data(base64Encoded: (try? String(contentsOf: keyURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
        fail("私钥格式不对（应为 base64 单行）")
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("私钥无法解析为 Ed25519 私钥")
    }
    guard let payload = FileManager.default.contents(atPath: path) else {
        fail("读不到待签名文件：\(path)")
    }

    let signature = try! key.signature(for: payload)
    let out = path + ".sig"
    do {
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: out))
    } catch {
        fail("写签名失败：\(error.localizedDescription)")
    }
    print("已签名 \(path) → \(out)（\(signature.count) 字节）")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--generate":
    generate()
case "--sign":
    guard arguments.count >= 2 else { fail("用法：--sign <file>") }
    sign(arguments[1])
default:
    print("用法：swift scripts/sign_update.swift [--generate | --sign <file>]")
    exit(2)
}
