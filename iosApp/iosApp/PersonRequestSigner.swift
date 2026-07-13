import CryptoKit
import Foundation

protocol ZhihuRequestSigning: Sendable {
    func applySignature(to request: inout URLRequest, cookies: [String: String], body: Data?)
}

struct ZhihuRequestSigner: ZhihuRequestSigning {
    func applySignature(to request: inout URLRequest, cookies: [String: String], body: Data?) {
        guard let url = request.url,
              let dc0 = cookies["d_c0"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dc0.isEmpty
        else { return }
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) }
        request.setValue(ZhihuRequestSignature.zse93, forHTTPHeaderField: "x-zse-93")
        request.setValue(
            ZhihuRequestSignature.zse96(url: url, dc0: dc0, body: bodyString),
            forHTTPHeaderField: "x-zse-96"
        )
        request.setValue("fetch", forHTTPHeaderField: "x-requested-with")
    }
}

enum ZhihuRequestSignature {
    static let zse93 = "101_3_3.0"

    static func zse96(url: URL, dc0: String, body: String?) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var pathname = components?.percentEncodedPath ?? url.path
        if pathname.isEmpty { pathname = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            pathname += "?\(query)"
        }
        let source = [zse93, pathname, dc0, body].compactMap { $0 }.joined(separator: "+")
        let digest = Insecure.MD5.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "2.0_\(ZseV4.encrypt(digest))"
    }
}

private enum ZseV4 {
    private static let roundKeys: [UInt32] = [
        1170614578, 1024848638, 1413669199, 3951632832, 3528873006, 2921909214, 4151847688, 3997739139,
        1933479194, 3323781115, 3888513386, 460404854, 3747539722, 2403641034, 2615871395, 2119585428,
        2265697227, 2035090028, 2773447226, 4289380121, 4217216195, 2200601443, 3051914490, 1579901135,
        1321810770, 456816404, 2903323407, 4065664991, 330002838, 3506006750, 363569021, 2347096187,
    ]

    private static let substitution: [UInt8] = [
        20, 223, 245, 7, 248, 2, 194, 209, 87, 6, 227, 253, 240, 128, 222, 91, 237, 9, 125, 157, 230,
        93, 252, 205, 90, 79, 144, 199, 159, 197, 186, 167, 39, 37, 156, 198, 38, 42, 43, 168, 217,
        153, 15, 103, 80, 189, 71, 191, 97, 84, 247, 95, 36, 69, 14, 35, 12, 171, 28, 114, 178, 148,
        86, 182, 32, 83, 158, 109, 22, 255, 94, 238, 151, 85, 77, 124, 254, 18, 4, 26, 123, 176, 232,
        193, 131, 172, 143, 142, 150, 30, 10, 146, 162, 62, 224, 218, 196, 229, 1, 192, 213, 27, 110,
        56, 231, 180, 138, 107, 242, 187, 54, 120, 19, 44, 117, 228, 215, 203, 53, 239, 251, 127, 81,
        11, 133, 96, 204, 132, 41, 115, 73, 55, 249, 147, 102, 48, 122, 145, 106, 118, 74, 190, 29, 16,
        174, 5, 177, 129, 63, 113, 99, 31, 161, 76, 246, 34, 211, 13, 60, 68, 207, 160, 65, 111, 82,
        165, 67, 169, 225, 57, 112, 244, 155, 51, 236, 200, 233, 58, 61, 47, 100, 137, 185, 64, 17, 70,
        234, 163, 219, 108, 170, 166, 59, 149, 52, 105, 24, 212, 78, 173, 45, 0, 116, 226, 119, 136,
        206, 135, 175, 195, 25, 92, 121, 208, 126, 139, 3, 75, 141, 21, 130, 98, 241, 40, 154, 66, 184,
        49, 181, 46, 243, 88, 101, 183, 8, 23, 72, 188, 104, 179, 210, 134, 250, 201, 164, 89, 216,
        202, 220, 50, 221, 152, 140, 33, 235, 214,
    ]

    private static let alphabet = Array("6fpLRqJO8M/c3jnYxFkUVC4ZIG12SiH=5v0mXDazWBTsuw7QetbKdoPyAl+hN9rgE")
    private static let key = Array("059053f7d15e01d7".utf8)

    static func encrypt(_ input: String) -> String {
        var plain: [UInt8] = [210, 0]
        plain.append(contentsOf: input.utf8)
        let padding = 16 - (plain.count % 16)
        plain.append(contentsOf: repeatElement(UInt8(padding), count: padding))

        var first = Array(repeating: UInt8(0), count: 16)
        for index in 0..<16 {
            first[index] = plain[index] ^ key[index] ^ 42
        }
        let firstCipher = block(first)
        var cipher = firstCipher
        var previous = firstCipher
        var offset = 16
        while offset < plain.count {
            let mixed = (0..<16).map { plain[offset + $0] ^ previous[$0] }
            previous = block(mixed)
            cipher.append(contentsOf: previous)
            offset += 16
        }
        return encode(cipher)
    }

    private static func block(_ input: [UInt8]) -> [UInt8] {
        var values = Array(repeating: UInt32(0), count: 36)
        for index in 0..<4 {
            values[index] = readUInt32(input, index * 4)
        }
        for index in 0..<32 {
            let transformed = transform(values[index + 1] ^ values[index + 2] ^ values[index + 3] ^ roundKeys[index])
            values[index + 4] = values[index] ^ transformed
        }
        return [values[35], values[34], values[33], values[32]].flatMap(bytes)
    }

    private static func transform(_ value: UInt32) -> UInt32 {
        let b0 = substitution[Int((value >> 24) & 0xff)]
        let b1 = substitution[Int((value >> 16) & 0xff)]
        let b2 = substitution[Int((value >> 8) & 0xff)]
        let b3 = substitution[Int(value & 0xff)]
        let substituted = (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
        return substituted ^ rotateLeft(substituted, 2) ^ rotateLeft(substituted, 10)
            ^ rotateLeft(substituted, 18) ^ rotateLeft(substituted, 24)
    }

    private static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func encode(_ input: [UInt8]) -> String {
        var bytes = input
        let remainder = bytes.count % 3
        if remainder != 0 { bytes.append(contentsOf: repeatElement(UInt8(0), count: 3 - remainder)) }
        var output = ""
        var maskIndex = 0
        var pointer = bytes.count - 1
        while pointer >= 2 {
            var value = 0
            for shift in 0..<3 {
                let byte = Int(bytes[pointer - shift])
                let mask = (58 >> (8 * (maskIndex % 4))) & 0xff
                maskIndex += 1
                value |= ((byte ^ mask) & 0xff) << (8 * shift)
            }
            output.append(alphabet[value & 63])
            output.append(alphabet[(value >> 6) & 63])
            output.append(alphabet[(value >> 12) & 63])
            output.append(alphabet[(value >> 18) & 63])
            pointer -= 3
        }
        return output
    }
}
