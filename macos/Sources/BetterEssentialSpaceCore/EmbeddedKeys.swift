/// Compile-time defaults for the two shared Nothing app keys (issue 06 decision:
/// publish them so a fresh clone works with no setup).
///
/// Both are APK-derived values shared by every install of the official app —
/// not personal credentials. A plain-text file under `~/.better-essential-space/`
/// overrides each value (see `RuntimeSecrets`), so a server-side key rotation
/// can be fixed without shipping a new build. Nothing personal belongs here:
/// no tokens, no device keys.
public enum EmbeddedKeys {
    /// Records-host key for the `auth` header, MD5 scheme (notes/03).
    public static let legacyAPIKey = "ZNtCkkSHqahusjfyouYxeaHUryeqKNaG"
    /// HMAC key for `x-app-signature` on account requests, login included (notes/02).
    public static let accountSigningKey = "YDU0vfkpb2MBU4kjx1r1WvGMRaMVJ8dj4ByhgPECE6PbdstiVFBectExlaKDrwSk"
}
