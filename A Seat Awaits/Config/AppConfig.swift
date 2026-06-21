//
//  AppConfig.swift
//  A Seat Awaits
//
//  Loads environment-specific configuration (Supabase URL + public anon key)
//  from `Secrets.plist`, which is kept out of source control. A committed
//  `Secrets.example.plist` documents the expected shape.
//

import Foundation

/// Strongly-typed access to runtime configuration loaded from the app bundle.
enum AppConfig {

    /// Errors surfaced when configuration is missing or malformed, so the UI can
    /// explain exactly what the developer needs to do.
    enum ConfigError: LocalizedError {
        case missingSecretsFile
        case missingKey(String)
        case invalidURL(String)

        var errorDescription: String? {
            switch self {
            case .missingSecretsFile:
                return "Secrets.plist was not found in the app bundle. Copy Secrets.example.plist to Secrets.plist and fill in your Supabase URL and anon key."
            case .missingKey(let key):
                return "Secrets.plist is missing the required key \"\(key)\"."
            case .invalidURL(let value):
                return "SUPABASE_URL is not a valid URL: \(value)"
            }
        }
    }

    /// The public marketing/guest origin used to build shareable guest links
    /// (e.g. the `/r/{token}` QR target). Non-secret; only used to construct
    /// URLs, never to call a server API.
    static let defaultPublicSiteURL = URL(string: "https://aseatawaits.com")!

    /// Parsed configuration values.
    struct Values {
        let supabaseURL: URL
        let supabaseAnonKey: String
        /// Public origin for guest-facing links. Defaults to `aseatawaits.com`.
        let publicSiteURL: URL
    }

    /// Lazily loaded, cached configuration. Throws a descriptive error when the
    /// secrets file is absent or incomplete.
    static func load() throws -> Values {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw ConfigError.missingSecretsFile
        }

        guard let urlString = (dict["SUPABASE_URL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty, urlString != "https://YOUR-PROJECT-ref.supabase.co"
        else {
            throw ConfigError.missingKey("SUPABASE_URL")
        }

        guard let anonKey = (dict["SUPABASE_ANON_KEY"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !anonKey.isEmpty, anonKey != "YOUR_PUBLIC_ANON_KEY"
        else {
            throw ConfigError.missingKey("SUPABASE_ANON_KEY")
        }

        guard let supabaseURL = URL(string: urlString), supabaseURL.scheme != nil else {
            throw ConfigError.invalidURL(urlString)
        }

        // PUBLIC_SITE_URL is optional; fall back to the production origin so the
        // app builds without extra setup. Only used to construct guest links.
        let publicSiteURL: URL
        if let siteString = (dict["PUBLIC_SITE_URL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !siteString.isEmpty {
            guard let parsed = URL(string: siteString), parsed.scheme != nil else {
                throw ConfigError.invalidURL(siteString)
            }
            publicSiteURL = parsed
        } else {
            publicSiteURL = defaultPublicSiteURL
        }

        return Values(supabaseURL: supabaseURL, supabaseAnonKey: anonKey, publicSiteURL: publicSiteURL)
    }
}
