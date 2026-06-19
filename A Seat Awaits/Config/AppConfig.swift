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

    /// Parsed configuration values.
    struct Values {
        let supabaseURL: URL
        let supabaseAnonKey: String
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

        return Values(supabaseURL: supabaseURL, supabaseAnonKey: anonKey)
    }
}
