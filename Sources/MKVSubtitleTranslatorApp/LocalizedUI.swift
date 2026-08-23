import SwiftUI
import MKVSubtitleCore

private func localizedUI(_ key: String) -> String {
    AppInterfaceLanguage.localized(key)
}

func Text(_ key: String) -> SwiftUI.Text {
    SwiftUI.Text(verbatim: localizedUI(key))
}

func Label(_ key: String, systemImage: String) -> SwiftUI.Label<SwiftUI.Text, SwiftUI.Image> {
    SwiftUI.Label {
        SwiftUI.Text(verbatim: localizedUI(key))
    } icon: {
        SwiftUI.Image(systemName: systemImage)
    }
}

func Button(
    _ key: String,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
) -> SwiftUI.Button<SwiftUI.Text> {
    SwiftUI.Button(role: role, action: action) {
        SwiftUI.Text(verbatim: localizedUI(key))
    }
}

func GroupBox<Content: View>(
    _ key: String,
    @ViewBuilder content: () -> Content
) -> SwiftUI.GroupBox<SwiftUI.Label<SwiftUI.Text, SwiftUI.EmptyView>, Content> {
    SwiftUI.GroupBox {
        content()
    } label: {
        SwiftUI.Label {
            SwiftUI.Text(verbatim: localizedUI(key))
        } icon: {
            EmptyView()
        }
    }
}

func Picker<SelectionValue: Hashable, Content: View>(
    _ key: String,
    selection: Binding<SelectionValue>,
    @ViewBuilder content: () -> Content
) -> SwiftUI.Picker<SwiftUI.Text, SelectionValue, Content> {
    SwiftUI.Picker(selection: selection, content: content) {
        SwiftUI.Text(verbatim: localizedUI(key))
    }
}

func LabeledContent<Content: View>(
    _ key: String,
    @ViewBuilder content: () -> Content
) -> SwiftUI.LabeledContent<SwiftUI.Text, Content> {
    SwiftUI.LabeledContent(content: content) {
        SwiftUI.Text(verbatim: localizedUI(key))
    }
}

func TextField(
    _ key: String,
    text: Binding<String>
) -> SwiftUI.TextField<SwiftUI.Text> {
    SwiftUI.TextField(text: text, prompt: nil) {
        SwiftUI.Text(verbatim: localizedUI(key))
    }
}

