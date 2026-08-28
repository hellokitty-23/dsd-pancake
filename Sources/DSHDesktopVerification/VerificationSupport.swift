import Darwin
import Dispatch
import Foundation
import DSHDesktopCore
import WebKit
@preconcurrency import SwiftTerm

extension DSHDesktopVerification {
    static func waitUntil(
        _ name: String,
        attempts: Int = 50,
        intervalNanoseconds: UInt64 = 100_000_000,
        condition: () async -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if await condition() { return }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        throw VerificationError("等待超时：\(name)")
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError(message) }
    }

}

struct VerificationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
