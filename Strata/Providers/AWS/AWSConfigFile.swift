import Foundation

/// A profile the user has configured, as the picker will show it.
struct AWSProfile: Sendable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    /// `region` from the profile, when set. Used as the starting region before
    /// per-bucket resolution.
    var region: String?
    /// True when the profile is backed by IAM Identity Center, which matters because
    /// its session expires and is refreshed with `aws sso login` rather than by
    /// editing a file.
    var isSSO: Bool
    /// True when the profile assumes a role, so the picker can say so.
    var assumesRole: Bool

    /// What the picker shows under the name.
    var summary: String {
        var parts: [String] = []
        if isSSO { parts.append("IAM Identity Center") }
        if assumesRole { parts.append("assumes a role") }
        if let region { parts.append(region) }
        return parts.isEmpty ? "Access keys" : parts.joined(separator: " · ")
    }
}

/// Parses `~/.aws/config` and `~/.aws/credentials` for the *names* of configured
/// profiles, so the connect picker can list them the way the Azure picker lists
/// storage accounts.
///
/// Deliberately only names and descriptive hints — never credential resolution. Secrets
/// stay with the AWS CLI, which `AWSCLICredentialProvider` asks at connect time. A
/// parser that started reading `aws_secret_access_key` would be reimplementing the
/// credential chain badly, and would put secrets in this process for no reason.
///
/// Pure and synchronous, so it is testable without a configured host.
enum AWSConfigFile {

    /// Reads whatever config exists. Missing files are not an error — a user with no
    /// AWS setup should see an empty picker with an explanation, not a failure.
    static func profiles(
        configContents: String?,
        credentialsContents: String?
    ) -> [AWSProfile] {
        var byName: [String: AWSProfile] = [:]

        // `~/.aws/config` sections are `[profile name]`, except `[default]`.
        for section in parseSections(configContents ?? "") {
            guard let name = profileName(fromConfigSection: section.name) else { continue }
            byName[name] = AWSProfile(
                name: name,
                region: section.values["region"],
                // `sso_session` is the newer spelling; `sso_start_url` the original.
                isSSO: section.values["sso_session"] != nil || section.values["sso_start_url"] != nil,
                assumesRole: section.values["role_arn"] != nil
            )
        }

        // `~/.aws/credentials` sections are bare profile names. A profile can appear in
        // only this file (plain access keys), so it still belongs in the list.
        for section in parseSections(credentialsContents ?? "") {
            let name = section.name
            guard !name.isEmpty, !name.hasPrefix("sso-session ") else { continue }
            if byName[name] == nil {
                byName[name] = AWSProfile(
                    name: name,
                    region: section.values["region"],
                    isSSO: false,
                    assumesRole: section.values["role_arn"] != nil
                )
            }
        }

        // `default` first, then alphabetical — the order a user expects to find them.
        return byName.values.sorted { left, right in
            if (left.name == "default") != (right.name == "default") {
                return left.name == "default"
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// Convenience over the real files on disk.
    static func profilesOnDisk() -> [AWSProfile] {
        profiles(
            configContents: try? String(contentsOf: AWSAuth.configFileURL, encoding: .utf8),
            credentialsContents: try? String(contentsOf: AWSAuth.credentialsFileURL, encoding: .utf8)
        )
    }

    // MARK: - INI parsing

    struct Section: Equatable {
        var name: String
        var values: [String: String]
    }

    /// A deliberately small INI reader for the subset AWS actually writes: `[section]`
    /// headers, `key = value` pairs, `#`/`;` comments. Nested/indented sub-settings
    /// (`s3 =` followed by indented keys) are skipped rather than misread as top-level
    /// keys.
    static func parseSections(_ contents: String) -> [Section] {
        var sections: [Section] = []
        var current: Section?
        var inNestedBlock = false

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            if trimmed.hasPrefix("[") {
                if let current { sections.append(current) }
                let name = trimmed
                    .drop(while: { $0 == "[" })
                    .prefix(while: { $0 != "]" })
                    .trimmingCharacters(in: .whitespaces)
                // Collapse runs of whitespace so `[profile   foo]` matches `[profile foo]`.
                current = Section(name: name.split(separator: " ").joined(separator: " "), values: [:])
                inNestedBlock = false
                continue
            }

            // An indented line belongs to the preceding nested block, not the section.
            let isIndented = line.first == " " || line.first == "\t"
            if isIndented && inNestedBlock { continue }

            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            // `key =` with nothing after it opens a nested block (`s3 =`).
            if value.isEmpty {
                inNestedBlock = true
                continue
            }
            inNestedBlock = false
            guard !key.isEmpty else { continue }
            current?.values[key.lowercased()] = value
        }

        if let current { sections.append(current) }
        return sections
    }

    /// `[default]` → `default`; `[profile foo]` → `foo`. Anything else in the config
    /// file (notably `[sso-session bar]`) is not a profile.
    static func profileName(fromConfigSection section: String) -> String? {
        if section == "default" { return "default" }
        guard section.hasPrefix("profile ") else { return nil }
        let name = String(section.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
