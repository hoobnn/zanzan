import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let zanzanBackup = UTType(
        exportedAs: "com.ikuyu.zanzan.backup",
        conformingTo: .package
    )
}

struct ZanzanBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zanzanBackup] }

    let package: ZanzanBackupPackage

    init(package: ZanzanBackupPackage) {
        self.package = package
    }

    init(configuration: ReadConfiguration) throws {
        package = try ZanzanBackupPackage(fileWrapper: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        package.fileWrapper()
    }
}
