import Foundation

/// Setup research is not a connector. These entries cannot fabricate a connected provider.
public struct ConnectionResearch: Sendable {
    public let name: String
    public let status: String
    public let instructions: String
    public let source: String
    public var iconText: String {
        if name.hasPrefix("Grok") { return "𝕏" }
        if name == "Higgsfield" { return "H" }
        if name == "Arcads" { return "Ar" }
        return "C"
    }

    public static let entries: [ConnectionResearch] = [
        .init(name: "Higgsfield", status: "Setup research · native connector pending verification",
              instructions: "Higgsfield's official CLI can read account credits; its chat/MCP connection is not automatically shared with UsageRail. The published login is higgsfield auth login, and account status --json reads credits. UsageRail won't launch that CLI until its executable and provenance have been reviewed. No API key or browser cookie should be pasted here. In Higgsfield: avatar → Manage Account → Subscription shows balance; Usage shows credit history. Website credits and Cloud API billing must not be mixed. No automatic install, login, generation or token extraction is performed.",
              source: "https://higgsfield.ai/creator-hub/help-center/integrations/how-do-i-access-higgsfield-via-cli"),
        .init(name: "Arcads", status: "Blocked · no balance endpoint in the reviewed public API",
              instructions: "Arcads documents Settings → Public API → Generate credentials (Client ID and Client Secret). However, the public OpenAPI reviewed on 2026-09-05 exposes creation/history operations, not an account-credit balance endpoint. Do not generate or enter credentials just for this monitor yet. A working balance integration requires Arcads to document a read-only balance API. UsageRail cannot infer remaining credits from video history or mark login as a successful usage connection.",
              source: "https://external-api.arcads.ai/docs"),
        .init(name: "Grok · SuperGrok", status: "Web subscription · no verified public quota connector",
              instructions: "This covers Grok on the website/app, including SuperGrok. It is separate from xAI API billing. The official FAQ describes a shared weekly allowance for paid Chat, Imagine, Voice and Build. No public subscription-usage endpoint was verified in the reviewed documentation. Use Grok's own usage/subscription screen; this entry stays hidden from the usage bar until an actual quota source is available. An xAI inference or Management API key cannot reveal SuperGrok allowance. Do not copy browser cookies or session tokens into UsageRail.",
              source: "https://docs.x.ai/grok/faq"),
        .init(name: "Grok · xAI API", status: "Documented billing API · advanced HTTPS setup available",
              instructions: "xAI Console → Settings → Management Keys provides a management key, separate from an inference API key. A team ID is also required. Only use a dedicated billing-read key, not a broad admin key. In + Add web app: name it xAI API ledger; GET endpoint https://management-api.x.ai/v1/billing/teams/YOUR_TEAM_ID/prepaid/balance; authentication Bearer; usage field /total/val; unit USD; scale 0.01. Enter your team ID in place of YOUR_TEAM_ID. This displays the signed API ledger value in dollars, NOT an inferred positive available-credit balance and NOT SuperGrok quota. Confirm the sign and amount against your Console before relying on it. Test & Add must succeed before it appears.",
              source: "https://docs.x.ai/developers/management-api-guide"),
        .init(name: "Cursor", status: "Team/admin API research · native connector not implemented",
              instructions: "Cursor documents team usage and spend through its Admin API, with access dependent on the account/plan and administrator permissions. These are team billing metrics, not a universal personal quota percentage. Use the official dashboard for now. No admin key is accepted by UsageRail until a least-privilege connector is implemented. Some usage data is hourly; polling it every few seconds would not make it realtime.",
              source: "https://prod.cursor.com/docs/account/teams/admin-api")
    ]
}
