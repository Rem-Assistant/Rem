import Foundation
import Testing
@testable import RemClaw

@MainActor
struct SkillModelsTests {

    @Test func missingSingleBinaryNamesTheTool() throws {
        let skill = try decodeSkill(
            missing: #"{"bins":["gh"]}"#,
            eligible: false,
            install: #"[{"id":"brew-0","kind":"brew","label":"Install gh (brew)","bins":["gh"]}]"#
        )

        #expect(skill.missingShortLabel == "Install gh")
        #expect(skill.installLabel(for: "gh") == "Install gh (brew)")
        #expect(skill.requirementDisplayRows == [
            SkillRequirementDisplayRow(
                id: "bin-gh",
                kind: .binary,
                status: .actionAvailable,
                title: "gh is not installed",
                detail: "Install gh (brew)",
                actionKind: .installTool(
                    installerID: "brew-0",
                    installerKind: "brew",
                    label: "Install gh (brew)"
                )
            )
        ])
    }

    @Test func missingMultipleBinariesNamesTheFirstTools() throws {
        let skill = try decodeSkill(
            missing: #"{"bins":["gh","jq"]}"#,
            eligible: false
        )

        #expect(skill.missingShortLabel == "Install gh and jq")
    }

    @Test func missingEnvironmentValueNamesTheKey() throws {
        let skill = try decodeSkill(
            missing: #"{"env":["CUSTOM_ENV"]}"#,
            eligible: false
        )

        #expect(skill.missingShortLabel == "Set CUSTOM_ENV")
        #expect(skill.requirementDisplayRows.first?.kind == .config)
        #expect(skill.requirementDisplayRows.first?.title == "Set CUSTOM_ENV")
    }

    @Test func macOnlyMissingBinaryIsReportedAsPlatformMismatch() throws {
        let skill = try decodeSkill(
            missing: #"{"bins":["osascript"]}"#,
            eligible: false
        )

        #expect(skill.missingShortLabel == "Requires macOS")
        #expect(skill.hasPlatformMismatch)
        #expect(skill.installLabel(for: "osascript") == nil)
        #expect(skill.requirementDisplayRows.first == SkillRequirementDisplayRow(
            id: "platform-mac",
            kind: .platform,
            status: .blocked,
            title: "Requires macOS",
            detail: "This skill needs Mac-only tools and is not available on the active cloud machine yet.",
            actionKind: nil
        ))
    }

    @Test func missingAnyBinaryNamesAlternatives() throws {
        let skill = try decodeSkill(
            missing: #"{"anyBins":["python3","python"]}"#,
            eligible: false
        )

        #expect(skill.missingShortLabel == "Install python3 or python")
        #expect(skill.missing?.hasAnyRequirement == true)
    }

    @Test func missingConfigNamesPath() throws {
        let skill = try decodeSkill(
            missing: #"{"config":["~/.config/example.json"]}"#,
            eligible: false
        )

        #expect(skill.missingShortLabel == "Configure ~/.config/example.json")
        #expect(skill.missing?.hasAnyRequirement == true)
        #expect(skill.requirementDisplayRows.first?.kind == .config)
        #expect(skill.requirementDisplayRows.first?.title == "Configure ~/.config/example.json")
        #expect(skill.requirementDisplayRows.first?.actionKind == .manualGatewaySetup)
    }

    @Test func missingOSNamesPlatform() throws {
        let skill = try decodeSkill(
            missing: #"{"os":["linux"]}"#,
            eligible: false
        )

        #expect(skill.missingShortLabel == "Requires Linux")
        #expect(skill.hasPlatformMismatch)
        #expect(skill.requirementDisplayRows.first?.detail == "This skill is not available on the active machine yet.")
        #expect(skill.requirementDisplayRows.first?.actionKind == nil)
    }

    @Test func knownAuthEnvironmentMapsToConnectorAction() throws {
        let skill = try decodeSkill(
            missing: #"{"env":["GITHUB_TOKEN"]}"#,
            eligible: false
        )

        #expect(skill.connectorRequirementProviders == [.github])
        #expect(skill.connectorRequirementsSummaryTitle == "Needs GitHub authorization")
        #expect(skill.connectorRequirementsSummaryDetail == "Authorize GitHub in Connectors for this Rem account. The active machine can reuse that account authorization when the skill runs.")
        #expect(skill.requirementDisplayRows.first == SkillRequirementDisplayRow(
            id: "env-GITHUB_TOKEN",
            kind: .auth,
            status: .actionAvailable,
            title: "Connect GitHub",
            detail: "Use the GitHub Connector to authorize this skill for this Rem account. The active machine can reuse that authorization when the skill runs.",
            actionKind: .openConnector(.github)
        ))
        #expect(SkillConnectorProvider.github.skillHandoffDetail.contains("active machine can reuse"))
        #expect(SkillConnectorProvider.github.skillHandoffDetail.contains("does not need a raw GitHub token"))
        #expect(!skill.requirementDisplayRows.first!.detail.contains("GITHUB_TOKEN on the gateway"))
    }

    @Test func firstWaveAuthEnvironmentsMapToConnectorActions() throws {
        let skill = try decodeSkill(
            missing: #"{"env":["GMAIL_ACCESS_TOKEN","GOOGLE_ACCESS_TOKEN","NOTION_ACCESS_TOKEN"]}"#,
            eligible: false
        )

        #expect(skill.requirementDisplayRows.map(\.title) == [
            "Connect Gmail",
            "Connect Google Workspace",
            "Connect Notion"
        ])
        #expect(skill.requirementDisplayRows.map(\.actionKind) == [
            .openConnector(.gmail),
            .openConnector(.google),
            .openConnector(.notion)
        ])
        #expect(skill.connectorRequirementProviders == [.gmail, .google, .notion])
        #expect(skill.connectorRequirementsSummaryTitle == "Needs 3 account authorizations")
        #expect(skill.connectorRequirementsSummaryDetail == "Authorize Gmail, Google Workspace, and Notion in Connectors for this Rem account. The active machine can reuse that account authorization when the skill runs.")
        #expect(skill.requirementDisplayRows.map(\.detail) == [
            "Use the Gmail Connector to authorize this skill for this Rem account. The active machine can reuse that authorization when the skill runs.",
            "Use the Google Workspace Connector to authorize this skill for this Rem account. The active machine can reuse that umbrella authorization when scopes are enabled.",
            "Use the Notion Connector to authorize this skill for this Rem account and workspace. The active machine can reuse that authorization when the skill runs."
        ])
        #expect(!skill.requirementDisplayRows.map(\.detail).joined(separator: "\n").contains("on the gateway"))
        #expect(SkillConnectorProvider.google.skillHandoffDetail.contains("umbrella authorization"))
        #expect(SkillConnectorProvider.google.skillHandoffDetail.contains("Drive, Docs, Slides, and Calendar"))
    }

    @Test func apiKeyEnvironmentDoesNotMapToOAuthConnector() throws {
        let skill = try decodeSkill(
            missing: #"{"env":["GOOGLE_API_KEY"]}"#,
            eligible: false
        )

        #expect(skill.requirementDisplayRows.first == SkillRequirementDisplayRow(
            id: "env-GOOGLE_API_KEY",
            kind: .auth,
            status: .blocked,
            title: "Connect or configure GOOGLE_API_KEY",
            detail: "This looks like an account credential. Use the matching Connector when available, or configure the secret on the active machine outside Rem.",
            actionKind: nil
        ))
        #expect(skill.connectorRequirementProviders == [])
        #expect(skill.connectorRequirementsSummaryTitle == nil)
        #expect(skill.connectorRequirementsSummaryDetail == nil)
    }

    @Test func skillConnectorProviderMapsOAuthProviderIds() {
        #expect(SkillConnectorProvider.github.matchesOAuthProviderId("github"))
        #expect(!SkillConnectorProvider.github.matchesOAuthProviderId("gitlab"))
        #expect(SkillConnectorProvider.gmail.matchesOAuthProviderId("gmail"))
        #expect(!SkillConnectorProvider.gmail.matchesOAuthProviderId("google"))
        #expect(SkillConnectorProvider.google.matchesOAuthProviderId("google"))
        #expect(SkillConnectorProvider.google.matchesOAuthProviderId("google-calendar"))
        #expect(SkillConnectorProvider.google.matchesOAuthProviderId("google-drive"))
        #expect(!SkillConnectorProvider.google.matchesOAuthProviderId("gmail"))
        #expect(SkillConnectorProvider.notion.matchesOAuthProviderId("notion"))
    }

    @Test func unknownAuthEnvironmentDoesNotGuessConnectorAction() throws {
        let skill = try decodeSkill(
            missing: #"{"env":["ACME_TOKEN"]}"#,
            eligible: false
        )

        #expect(skill.requirementDisplayRows.first == SkillRequirementDisplayRow(
            id: "env-ACME_TOKEN",
            kind: .auth,
            status: .blocked,
            title: "Connect or configure ACME_TOKEN",
            detail: "This looks like an account credential. Use the matching Connector when available, or configure the secret on the active machine outside Rem.",
            actionKind: nil
        ))
    }

    @Test func manifestInstallerPolicyAllowsKnownInstallerKinds() throws {
        try SkillInstallRequestPolicy.validateManifestInstaller(
            name: "github",
            installId: "brew-gh",
            installerKind: "brew"
        )
        try SkillInstallRequestPolicy.validateManifestInstaller(
            name: "node-tools",
            installId: "node-package",
            installerKind: "node"
        )
        try SkillInstallRequestPolicy.validateManifestInstaller(
            name: "go-tools",
            installId: "go-package",
            installerKind: "go"
        )
        try SkillInstallRequestPolicy.validateManifestInstaller(
            name: "uv-tool",
            installId: "uv-package",
            installerKind: "uv"
        )
        try SkillInstallRequestPolicy.validateManifestInstaller(
            name: "download-tool",
            installId: "download",
            installerKind: "download"
        )
    }

    @Test func manifestInstallerPolicyRejectsMissingOrUnknownInstallerInputs() {
        #expect(throws: SkillInstallRequestValidationError.emptySkillName) {
            try SkillInstallRequestPolicy.validateManifestInstaller(
                name: " ",
                installId: "brew-gh",
                installerKind: "brew"
            )
        }
        #expect(throws: SkillInstallRequestValidationError.emptyInstallId) {
            try SkillInstallRequestPolicy.validateManifestInstaller(
                name: "github",
                installId: "",
                installerKind: "brew"
            )
        }
        #expect(throws: SkillInstallRequestValidationError.unsafeInstallId("../brew")) {
            try SkillInstallRequestPolicy.validateManifestInstaller(
                name: "github",
                installId: "../brew",
                installerKind: "brew"
            )
        }
        #expect(throws: SkillInstallRequestValidationError.unsupportedManifestInstallerKind("shell")) {
            try SkillInstallRequestPolicy.validateManifestInstaller(
                name: "github",
                installId: "shell-gh",
                installerKind: "shell"
            )
        }
        #expect(throws: SkillInstallRequestValidationError.unsupportedManifestInstallerKind("bundled")) {
            try SkillInstallRequestPolicy.validateManifestInstaller(
                name: "github",
                installId: "bundled",
                installerKind: "bundled"
            )
        }
    }

    @Test func clawHubSlugPolicyAllowsOnlySafePackageSlugs() throws {
        try SkillInstallRequestPolicy.validateClawHubSlug("github")
        try SkillInstallRequestPolicy.validateClawHubSlug("google-calendar-2")

        #expect(throws: SkillInstallRequestValidationError.emptyClawHubSlug) {
            try SkillInstallRequestPolicy.validateClawHubSlug(" ")
        }
        #expect(throws: SkillInstallRequestValidationError.unsafeClawHubSlug("google.calendar_2")) {
            try SkillInstallRequestPolicy.validateClawHubSlug("google.calendar_2")
        }
        #expect(throws: SkillInstallRequestValidationError.unsafeClawHubSlug("../github")) {
            try SkillInstallRequestPolicy.validateClawHubSlug("../github")
        }
        #expect(throws: SkillInstallRequestValidationError.unsafeClawHubSlug("github;rm -rf")) {
            try SkillInstallRequestPolicy.validateClawHubSlug("github;rm -rf")
        }
    }

    @Test func skillIconUsesUpstreamEmojiWhenAvailable() throws {
        let skill = try decodeSkill(
            missing: "{}",
            eligible: true,
            extraFields: #""emoji":"📝","homepage":"https://example.com""#
        )

        #expect(skill.emoji == "📝")
        #expect(skill.homepage == "https://example.com")
        #expect(skill.iconSpec.kind == .emoji("📝"))
    }

    @Test func skillIconIgnoresNonEmojiMetadata() throws {
        let skill = try decodeSkill(
            skillKey: "backup-disk",
            name: "Backup Disk",
            description: "Save documents",
            missing: "{}",
            eligible: true,
            extraFields: #""emoji":"disk""#
        )

        #expect(skill.iconSpec.kind == .symbol("doc.text.fill"))
    }

    @Test func skillIconFallsBackByCapabilityKeyword() throws {
        let skill = try decodeSkill(
            skillKey: "apple-reminders",
            name: "Apple Reminders",
            description: "List and complete tasks",
            missing: "{}",
            eligible: true
        )

        #expect(skill.iconSpec.kind == .symbol("calendar.badge.clock"))
        #expect(skill.iconSpec.tintName == "orange")
    }

    @Test func skillIconMatchesTokensWithoutSubstringBleed() throws {
        let skill = try decodeSkill(
            skillKey: "doctor-status",
            name: "Doctor Status",
            description: "Review health logs",
            missing: "{}",
            eligible: true
        )

        #expect(skill.iconSpec.kind == .symbol("stethoscope"))
        #expect(skill.iconSpec.tintName == "red")
    }

    @Test func clawHubResultIconFallsBackBySummary() {
        let result = ClawHubSearchResult(
            slug: "github",
            displayName: "GitHub",
            summary: "Create and review pull requests"
        )

        #expect(result.iconSpec.kind == .symbol("chevron.left.forwardslash.chevron.right"))
        #expect(result.iconSpec.tintName == "indigo")
    }

    private func decodeSkill(
        skillKey: String = "test.skill",
        name: String = "Test Skill",
        description: String = "Example skill",
        missing: String,
        eligible: Bool,
        install: String = "[]",
        extraFields: String? = nil
    ) throws -> SkillEntry {
        let extra = extraFields.map { ",\n              \($0)" } ?? ""
        let json = """
        {
          "skills": [
            {
              "skillKey": "\(skillKey)",
              "name": "\(name)",
              "description": "\(description)",
              "eligible": \(eligible),
              "missing": \(missing),
              "install": \(install)
              \(extra)
            }
          ],
          "workspaceDir": "/Users/test/project"
        }
        """
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONDecoder().decode(SkillsStatusResponse.self, from: data).skills.first)
    }
}
