import UIKit

@MainActor
protocol AppIconApplication: AnyObject {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }

    func setAlternateIconName(_ alternateIconName: String?) async throws
}

extension UIApplication: AppIconApplication {}
