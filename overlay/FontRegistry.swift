import AppKit
import CoreText

/// Resolves the UI font family. Millie ships Google Sans (OFL) bundled in the
/// app at `Contents/Resources/Fonts/*.ttf`; we register those faces at process
/// start and use them everywhere. Söhne (the webapp font) is honored only if a
/// copy happens to be installed system-wide. System font (SF Pro) is the final
/// fallback.
enum FontRegistry {
    /// "Google Sans" once its bundled faces are registered, else nil.
    static let googleSansFamily: String? = {
        registerBundledFonts()
        let families = NSFontManager.shared.availableFontFamilies
        return families.contains("Google Sans") ? "Google Sans" : nil
    }()

    static let soehneFamily: String? = {
        let families = NSFontManager.shared.availableFontFamilies
        let candidates = ["Söhne", "Soehne", "Söhne Buch", "Soehne Buch"]
        for name in candidates where families.contains(name) {
            return name
        }
        return nil
    }()

    private static var didRegister = false
    /// Registers every `.ttf` in the app bundle's `Fonts/` directory into the
    /// current process. Idempotent; safe if the directory is missing.
    private static func registerBundledFonts() {
        guard !didRegister else { return }
        didRegister = true
        guard let resURL = Bundle.main.resourceURL else { return }
        let fontsDir = resURL.appendingPathComponent("Fonts", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: fontsDir, includingPropertiesForKeys: nil) else { return }
        for url in items where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
