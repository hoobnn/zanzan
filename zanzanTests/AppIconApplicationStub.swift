import Foundation
@testable import zanzan

@MainActor
final class AppIconApplicationStub: AppIconApplication {
    let supportsAlternateIcons: Bool
    var alternateIconName: String?
    var nextError: (any Error)?
    private(set) var requestedIconNames: [String?] = []

    init(supportsAlternateIcons: Bool = true, alternateIconName: String? = nil) {
        self.supportsAlternateIcons = supportsAlternateIcons
        self.alternateIconName = alternateIconName
    }

    func setAlternateIconName(_ alternateIconName: String?) async throws {
        requestedIconNames.append(alternateIconName)

        if let nextError {
            throw nextError
        }

        self.alternateIconName = alternateIconName
    }
}
