import SwiftUI

struct ZanzanTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .zanzanControlSurface()
    }
}

extension TextFieldStyle where Self == ZanzanTextFieldStyle {
    static var zanzan: Self { ZanzanTextFieldStyle() }
}
