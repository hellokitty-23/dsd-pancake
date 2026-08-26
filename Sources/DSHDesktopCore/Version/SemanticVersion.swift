import Foundation

public struct SemanticVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
    private enum PrereleaseIdentifier: Comparable, Equatable, Sendable {
        case numeric(Int)
        case text(String)

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(left), .numeric(right)):
                left < right
            case (.numeric, .text):
                true
            case (.text, .numeric):
                false
            case let (.text(left), .text(right)):
                left < right
            }
        }
    }

    public let rawValue: String
    private let major: Int
    private let minor: Int
    private let patch: Int
    private let prerelease: [PrereleaseIdentifier]

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let versionAndBuild = withoutPrefix.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard !versionAndBuild.isEmpty,
              versionAndBuild.count <= 2,
              versionAndBuild.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        let versionAndPrerelease = versionAndBuild[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !versionAndPrerelease.isEmpty,
              versionAndPrerelease.count <= 2,
              versionAndPrerelease.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        let core = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseCoreNumber(core[0]),
              let minor = Self.parseCoreNumber(core[1]),
              let patch = Self.parseCoreNumber(core[2]) else {
            return nil
        }

        var identifiers: [PrereleaseIdentifier] = []
        if versionAndPrerelease.count == 2 {
            for rawIdentifier in versionAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false) {
                let identifier = String(rawIdentifier)
                guard !identifier.isEmpty,
                      identifier.unicodeScalars.allSatisfy({
                          CharacterSet.alphanumerics.contains($0) || $0 == "-"
                      }) else {
                    return nil
                }
                if identifier.allSatisfy(\.isNumber) {
                    guard identifier == "0" || !identifier.hasPrefix("0"),
                          let number = Int(identifier) else {
                        return nil
                    }
                    identifiers.append(.numeric(number))
                } else {
                    identifiers.append(.text(identifier))
                }
            }
        }

        if versionAndBuild.count == 2 {
            let buildIdentifiers = versionAndBuild[1].split(separator: ".", omittingEmptySubsequences: false)
            guard buildIdentifiers.allSatisfy({ identifier in
                !identifier.isEmpty && identifier.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || $0 == "-"
                }
            }) else {
                return nil
            }
        }

        self.rawValue = withoutPrefix
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = identifiers
    }

    public var description: String { rawValue }
    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func extract(from output: String) -> Self? {
        let pattern = #"(?:^|[^0-9A-Za-z-])v?([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?![0-9A-Za-z.+-])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..<output.endIndex, in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Self(String(output[range]))
    }

    private static func parseCoreNumber(_ value: Substring) -> Int? {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              value == "0" || !value.hasPrefix("0") else {
            return nil
        }
        return Int(value)
    }
}
