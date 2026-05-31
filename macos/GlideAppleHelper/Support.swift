import Darwin
import Foundation
import Security

extension GlideAppleHelper {
    static func requireSignedHelper(_ feature: String) throws {
        guard helperTeamIdentifier() != nil else {
            throw HelperError("\(feature) requires a signed app with a team identifier")
        }
    }

    static func helperTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        ) == errSecSuccess,
            let dict = info as? [String: Any],
            let teamIdentifier = dict[kSecCodeInfoTeamIdentifier as String] as? String,
            !teamIdentifier.isEmpty
        else {
            return nil
        }

        return teamIdentifier
    }

    static func readStdinJSON<T: Decodable>() throws -> T {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func printResponse(_ response: HelperResponse) {
        do {
            let data = try JSONEncoder().encode(response)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
                fflush(stdout)
            }
        } catch {
            print("{\"ok\":false,\"error\":\"failed to encode helper response\"}")
            fflush(stdout)
        }
    }

    static func printInstallEvent(_ event: AppleSpeechInstallEvent) {
        do {
            let data = try JSONEncoder().encode(event)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
                fflush(stdout)
            }
        } catch {
            print("{\"ok\":false,\"event\":\"failed\",\"modelId\":\"unknown\",\"error\":\"failed to encode install event\"}")
            fflush(stdout)
        }
    }
}
