use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MacosPermissionDiagnostics {
    pub platform: String,
    pub executable_path: Option<String>,
    pub bundle_path: Option<String>,
    pub accessibility_trusted: bool,
    pub codesign: CodeSignSummary,
    pub tcc_identity: TccIdentitySummary,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodeSignSummary {
    pub raw_available: bool,
    pub executable: Option<String>,
    pub identifier: Option<String>,
    pub format: Option<String>,
    pub signature: Option<String>,
    pub authorities: Vec<String>,
    pub team_identifier: Option<String>,
    pub timestamp: Option<String>,
    pub runtime_version: Option<String>,
    pub sealed_resources: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TccIdentitySummary {
    pub bundle_id: Option<String>,
    pub team_identifier: Option<String>,
    pub signature_kind: SignatureKind,
    pub stable_for_tcc: bool,
    pub stale_trust_risk: bool,
    pub repair_hint: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SignatureKind {
    DeveloperId,
    AppleDevelopment,
    AppleSigned,
    AdHoc,
    UnsignedOrRejected,
    Unknown,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TccRepairRequest {
    pub bundle_id: String,
    pub reset_accessibility: bool,
    pub reset_apple_events: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TccRepairReport {
    pub bundle_id: String,
    pub services: Vec<TccServiceRepair>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TccServiceRepair {
    pub service: String,
    pub success: bool,
    pub status_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

pub fn collect_macos_permission_diagnostics() -> MacosPermissionDiagnostics {
    collect_macos_permission_diagnostics_for_path(current_executable_path())
}

pub fn collect_macos_permission_diagnostics_for_path(
    executable_path: Option<PathBuf>,
) -> MacosPermissionDiagnostics {
    #[cfg(target_os = "macos")]
    {
        let bundle_path = executable_path.as_deref().and_then(find_app_bundle_path);
        let sign_target = bundle_path.as_deref().or(executable_path.as_deref());
        let codesign = sign_target.map(read_codesign_summary).unwrap_or_default();
        let accessibility_trusted = accessibility_is_trusted();
        let tcc_identity = summarize_tcc_identity(&codesign, accessibility_trusted);

        MacosPermissionDiagnostics {
            platform: "macos".to_string(),
            executable_path: executable_path.map(display_path),
            bundle_path: bundle_path.map(display_path),
            accessibility_trusted,
            codesign,
            tcc_identity,
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = executable_path;
        MacosPermissionDiagnostics {
            platform: std::env::consts::OS.to_string(),
            executable_path: None,
            bundle_path: None,
            accessibility_trusted: true,
            codesign: CodeSignSummary::default(),
            tcc_identity: TccIdentitySummary {
                bundle_id: None,
                team_identifier: None,
                signature_kind: SignatureKind::Unknown,
                stable_for_tcc: true,
                stale_trust_risk: false,
                repair_hint: None,
            },
        }
    }
}

pub fn parse_codesign_details(output: &str) -> CodeSignSummary {
    let mut summary = CodeSignSummary {
        raw_available: !output.trim().is_empty(),
        ..CodeSignSummary::default()
    };

    for line in output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        if let Some(value) = line.strip_prefix("Executable=") {
            summary.executable = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("Identifier=") {
            summary.identifier = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("Format=") {
            summary.format = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("Signature=") {
            summary.signature = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("Authority=") {
            summary.authorities.push(value.to_string());
        } else if let Some(value) = line.strip_prefix("TeamIdentifier=") {
            let value = value.trim();
            if !value.is_empty() && value != "not set" {
                summary.team_identifier = Some(value.to_string());
            }
        } else if let Some(value) = line.strip_prefix("Timestamp=") {
            summary.timestamp = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("Runtime Version=") {
            summary.runtime_version = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("Sealed Resources ") {
            summary.sealed_resources = Some(value.to_string());
        }
    }

    summary
}

pub fn signature_kind(summary: &CodeSignSummary) -> SignatureKind {
    if summary
        .signature
        .as_deref()
        .is_some_and(|signature| signature.eq_ignore_ascii_case("adhoc"))
    {
        return SignatureKind::AdHoc;
    }

    if summary
        .authorities
        .iter()
        .any(|authority| authority.starts_with("Developer ID Application:"))
    {
        return SignatureKind::DeveloperId;
    }

    if summary
        .authorities
        .iter()
        .any(|authority| authority.starts_with("Apple Development:"))
    {
        return SignatureKind::AppleDevelopment;
    }

    if summary
        .authorities
        .iter()
        .any(|authority| authority == "Apple Mac OS Application Signing")
    {
        return SignatureKind::AppleSigned;
    }

    if summary.raw_available && summary.authorities.is_empty() && summary.team_identifier.is_none()
    {
        return SignatureKind::UnsignedOrRejected;
    }

    SignatureKind::Unknown
}

pub fn summarize_tcc_identity(
    codesign: &CodeSignSummary,
    accessibility_trusted: bool,
) -> TccIdentitySummary {
    let signature_kind = signature_kind(codesign);
    let stable_for_tcc = matches!(
        signature_kind,
        SignatureKind::DeveloperId | SignatureKind::AppleDevelopment | SignatureKind::AppleSigned
    ) && codesign.identifier.is_some()
        && codesign.team_identifier.is_some();
    let stale_trust_risk = !accessibility_trusted
        && matches!(
            signature_kind,
            SignatureKind::AdHoc | SignatureKind::UnsignedOrRejected | SignatureKind::Unknown
        );
    let repair_hint = if stale_trust_risk {
        Some("macOS may show an enabled Accessibility row for a previous Zerm binary. Reset Accessibility and AppleEvents for com.arcusis.zerm, then add the currently installed app again.".to_string())
    } else if !accessibility_trusted {
        Some("Accessibility is not trusted for the current running process.".to_string())
    } else {
        None
    };

    TccIdentitySummary {
        bundle_id: codesign.identifier.clone(),
        team_identifier: codesign.team_identifier.clone(),
        signature_kind,
        stable_for_tcc,
        stale_trust_risk,
        repair_hint,
    }
}

#[cfg(target_os = "macos")]
pub fn reset_tcc_entries(request: TccRepairRequest) -> Result<TccRepairReport, String> {
    let bundle_id = request.bundle_id.trim();
    if bundle_id.is_empty() {
        return Err("bundle_id is required to reset macOS TCC entries".to_string());
    }
    if !request.reset_accessibility && !request.reset_apple_events {
        return Err("at least one TCC service reset must be explicitly requested".to_string());
    }

    let mut services = Vec::new();
    if request.reset_accessibility {
        services.push(reset_tcc_service("Accessibility", bundle_id)?);
    }
    if request.reset_apple_events {
        services.push(reset_tcc_service("AppleEvents", bundle_id)?);
    }

    Ok(TccRepairReport {
        bundle_id: bundle_id.to_string(),
        services,
    })
}

#[cfg(not(target_os = "macos"))]
pub fn reset_tcc_entries(_request: TccRepairRequest) -> Result<TccRepairReport, String> {
    Err("macOS TCC repair is only available on macOS".to_string())
}

#[cfg(target_os = "macos")]
fn accessibility_is_trusted() -> bool {
    unsafe { AXIsProcessTrusted() != 0 }
}

#[cfg(target_os = "macos")]
#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> std::ffi::c_uchar;
}

#[cfg(target_os = "macos")]
fn read_codesign_summary(path: &Path) -> CodeSignSummary {
    let output = std::process::Command::new("/usr/bin/codesign")
        .args(["-dv", "--verbose=4"])
        .arg(path)
        .output();

    match output {
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            let stdout = String::from_utf8_lossy(&out.stdout);
            parse_codesign_details(&format!("{stderr}{stdout}"))
        }
        Err(_) => CodeSignSummary::default(),
    }
}

#[cfg(target_os = "macos")]
fn reset_tcc_service(service: &str, bundle_id: &str) -> Result<TccServiceRepair, String> {
    let output = std::process::Command::new("/usr/bin/tccutil")
        .args(["reset", service, bundle_id])
        .output()
        .map_err(|e| format!("run tccutil reset {service}: {e}"))?;

    Ok(TccServiceRepair {
        service: service.to_string(),
        success: output.status.success(),
        status_code: output.status.code(),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    })
}

fn current_executable_path() -> Option<PathBuf> {
    std::env::current_exe().ok()
}

fn find_app_bundle_path(executable_path: &Path) -> Option<PathBuf> {
    executable_path
        .ancestors()
        .find(|path| path.extension().is_some_and(|extension| extension == "app"))
        .map(Path::to_path_buf)
}

fn display_path(path: PathBuf) -> String {
    path.display().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEVELOPER_ID_CODESIGN: &str = r#"
Executable=/Applications/Zerm.app/Contents/MacOS/zerm
Identifier=com.arcusis.zerm
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+7 location=embedded
Signature size=8995
Authority=Developer ID Application: Arcusis Ltd (ABCDE12345)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Apr 22, 2026 at 12:11:10 PM
Info.plist entries=31
TeamIdentifier=ABCDE12345
Runtime Version=26.0.0
Sealed Resources version=2 rules=13 files=9
Internal requirements count=1 size=184
"#;

    const ADHOC_CODESIGN: &str = r#"
Executable=/Applications/Zerm.app/Contents/MacOS/zerm
Identifier=com.arcusis.zerm
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+7 location=embedded
Signature=adhoc
Info.plist entries=31
TeamIdentifier=not set
Runtime Version=26.0.0
"#;

    #[test]
    fn parses_developer_id_codesign_details() {
        let summary = parse_codesign_details(DEVELOPER_ID_CODESIGN);

        assert!(summary.raw_available);
        assert_eq!(
            summary.executable.as_deref(),
            Some("/Applications/Zerm.app/Contents/MacOS/zerm")
        );
        assert_eq!(summary.identifier.as_deref(), Some("com.arcusis.zerm"));
        assert_eq!(summary.team_identifier.as_deref(), Some("ABCDE12345"));
        assert_eq!(summary.authorities.len(), 3);
        assert_eq!(
            summary.authorities.first().map(String::as_str),
            Some("Developer ID Application: Arcusis Ltd (ABCDE12345)")
        );
        assert_eq!(
            summary.timestamp.as_deref(),
            Some("Apr 22, 2026 at 12:11:10 PM")
        );
        assert_eq!(
            summary.sealed_resources.as_deref(),
            Some("version=2 rules=13 files=9")
        );
        assert_eq!(signature_kind(&summary), SignatureKind::DeveloperId);
    }

    #[test]
    fn parses_adhoc_codesign_as_unstable_identity() {
        let summary = parse_codesign_details(ADHOC_CODESIGN);
        let identity = summarize_tcc_identity(&summary, false);

        assert_eq!(summary.identifier.as_deref(), Some("com.arcusis.zerm"));
        assert_eq!(summary.signature.as_deref(), Some("adhoc"));
        assert_eq!(summary.team_identifier, None);
        assert_eq!(identity.signature_kind, SignatureKind::AdHoc);
        assert!(!identity.stable_for_tcc);
        assert!(identity.stale_trust_risk);
        assert!(identity.repair_hint.is_some());
    }

    #[test]
    fn developer_id_identity_is_stable_for_tcc() {
        let summary = parse_codesign_details(DEVELOPER_ID_CODESIGN);
        let identity = summarize_tcc_identity(&summary, false);

        assert_eq!(identity.bundle_id.as_deref(), Some("com.arcusis.zerm"));
        assert_eq!(identity.team_identifier.as_deref(), Some("ABCDE12345"));
        assert_eq!(identity.signature_kind, SignatureKind::DeveloperId);
        assert!(identity.stable_for_tcc);
        assert!(!identity.stale_trust_risk);
        assert_eq!(
            identity.repair_hint.as_deref(),
            Some("Accessibility is not trusted for the current running process.")
        );
    }

    #[test]
    fn finds_bundle_path_from_app_executable() {
        let path = Path::new("/Applications/Zerm.app/Contents/MacOS/zerm");

        assert_eq!(
            find_app_bundle_path(path).as_deref(),
            Some(Path::new("/Applications/Zerm.app"))
        );
    }
}
