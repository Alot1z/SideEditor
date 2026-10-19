import Foundation

public enum SideEditorSetup {
    public static let buildMode: String = {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }()
}
