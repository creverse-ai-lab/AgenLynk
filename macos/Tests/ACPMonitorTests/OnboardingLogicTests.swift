import Foundation

// Deterministic checks for the pure parsing/validation logic behind first-run
// onboarding: Node version parsing, install.json validity, and bootstrap
// result interpretation. None of these touch the filesystem, a real Node
// process, or the network.
@main
enum OnboardingLogicChecks {
    static func main() throws {
        try checkParseMajorVersion()
        try checkStableApplicationPath()
        try checkInstallStateValidity()
        try checkBootstrapResultParsing()
        try checkCurrentRuntimeParsing()
        try checkRuntimeProvisionerResultParsing()
        try checkBundledRuntimeErrorStableCodes()
        print("Swift onboarding logic checks passed")
    }

    /// A missing installed Gateway runtime is the one `BundledRuntimeError`
    /// case with a stable `monitor_*` code (see Models.swift for the same
    /// vocabulary on the decode/HTTP error paths); every other case is a
    /// local Node-discovery failure with no server-side equivalent.
    static func checkBundledRuntimeErrorStableCodes() throws {
        guard BundledRuntimeError.runtimeNotInstalled.stableCode == "monitor_not_installed" else {
            throw CheckError.failed("expected runtimeNotInstalled to carry the monitor_not_installed stable code")
        }
        guard BundledRuntimeError.runtimeNotInstalled.errorDescription == "설치된 Gateway runtime을 찾지 못했습니다. Lynk를 다시 시작해 설치를 완료하세요." else {
            throw CheckError.failed("expected runtimeNotInstalled to keep its existing localized description")
        }
        guard BundledRuntimeError.nodeNotFound.stableCode == nil else {
            throw CheckError.failed("expected nodeNotFound to carry no stable code")
        }
        guard BundledRuntimeError.resourceNotFound("sidecar/src/server/monitor.js").stableCode == nil else {
            throw CheckError.failed("expected resourceNotFound to carry no stable code")
        }
    }

    static func checkStableApplicationPath() throws {
        guard BundledRuntime.isStableApplicationPath("/Applications/Lynk.app") else {
            throw CheckError.failed("expected /Applications/Lynk.app to be stable")
        }
        guard !BundledRuntime.isStableApplicationPath("/Volumes/Lynk/Lynk.app") else {
            throw CheckError.failed("expected a mounted DMG path to be rejected")
        }
        guard !BundledRuntime.isStableApplicationPath("/private/var/folders/x/AppTranslocation/Lynk.app") else {
            throw CheckError.failed("expected an AppTranslocation path to be rejected")
        }
    }

    static func checkParseMajorVersion() throws {
        guard BundledRuntime.parseMajorVersion("v22.4.0") == 22 else {
            throw CheckError.failed("expected v22.4.0 to parse as major 22")
        }
        guard BundledRuntime.parseMajorVersion("26.5.0") == 26 else {
            throw CheckError.failed("expected 26.5.0 to parse as major 26")
        }
        guard BundledRuntime.parseMajorVersion("v9.0.0") == 9 else {
            throw CheckError.failed("expected v9.0.0 to parse as major 9")
        }
        guard BundledRuntime.parseMajorVersion("") == nil else {
            throw CheckError.failed("expected empty string to fail to parse")
        }
        guard BundledRuntime.parseMajorVersion("not-a-version") == nil else {
            throw CheckError.failed("expected garbage input to fail to parse")
        }
    }

    static func checkInstallStateValidity() throws {
        let valid = """
        {"version":1,"managedMcp":{},"identity":{"token":"0123456789012345678901234","rootId":"main-abc"}}
        """
        guard InstallStateChecker.isValid(data: Data(valid.utf8)) else {
            throw CheckError.failed("expected well-formed install.json to be valid")
        }

        let missingIdentity = """
        {"version":1,"managedMcp":{}}
        """
        guard !InstallStateChecker.isValid(data: Data(missingIdentity.utf8)) else {
            throw CheckError.failed("expected install.json without identity to be invalid")
        }

        let shortToken = """
        {"version":1,"identity":{"token":"short","rootId":"main-abc"}}
        """
        guard !InstallStateChecker.isValid(data: Data(shortToken.utf8)) else {
            throw CheckError.failed("expected a too-short Control token to be invalid")
        }

        let wrongVersion = """
        {"version":2,"identity":{"token":"0123456789012345678901234","rootId":"main-abc"}}
        """
        guard !InstallStateChecker.isValid(data: Data(wrongVersion.utf8)) else {
            throw CheckError.failed("expected an unsupported install state version to be invalid")
        }

        guard !InstallStateChecker.isValid(data: Data("not json".utf8)) else {
            throw CheckError.failed("expected non-JSON content to be invalid")
        }
    }

    static func checkBootstrapResultParsing() throws {
        let healthyOutput = """
        {"ok":true,"health":{"checked":true,"ok":true}}
        """
        guard InstallerController.parseResult(healthyOutput)?.ok == true else {
            throw CheckError.failed("expected a healthy install result to parse as ok")
        }

        let unhealthyOutput = """
        {"ok":true,"health":{"checked":true,"ok":false}}
        """
        guard InstallerController.parseResult(unhealthyOutput)?.ok == false else {
            throw CheckError.failed("expected a failed health check to parse as not ok")
        }

        let noHealthCheckOutput = """
        {"ok":true,"health":{"checked":false}}
        """
        guard InstallerController.parseResult(noHealthCheckOutput)?.ok == true else {
            throw CheckError.failed("expected an unchecked health result to still parse as ok")
        }

        let notOkOutput = """
        {"ok":false}
        """
        guard InstallerController.parseResult(notOkOutput)?.ok == false else {
            throw CheckError.failed("expected ok:false to parse as not ok")
        }

        guard InstallerController.parseResult("not json") == nil else {
            throw CheckError.failed("expected unparseable output to return nil")
        }

        guard InstallerController.parseResult("{}") == nil else {
            throw CheckError.failed("expected output without an ok field to return nil")
        }
    }

    static func checkCurrentRuntimeParsing() throws {
        let valid = """
        {"formatVersion":1,"runtimeRoot":"/Users/test/.acp-gateway/runtime/versions/1.3.1-abcdef","gatewayVersion":"1.3.1","gatewayBuildId":"abcdef"}
        """
        guard let pointer = BundledRuntime.parseCurrentRuntime(data: Data(valid.utf8)) else {
            throw CheckError.failed("expected a well-formed current.json to parse")
        }
        guard pointer.runtimeRoot.path == "/Users/test/.acp-gateway/runtime/versions/1.3.1-abcdef" else {
            throw CheckError.failed("expected the parsed runtimeRoot path to round-trip exactly")
        }
        guard !pointer.runtimeRoot.path.contains(".app") else {
            throw CheckError.failed("installed resolution must never point back under a .app bundle")
        }

        let pointingIntoBundle = """
        {"formatVersion":1,"runtimeRoot":"/Applications/Lynk.app/Contents/Resources/runtime","gatewayVersion":"1.3.1","gatewayBuildId":"abcdef"}
        """
        guard BundledRuntime.parseCurrentRuntime(data: Data(pointingIntoBundle.utf8)) == nil else {
            throw CheckError.failed("expected a current.json pointing back into a .app bundle to be rejected")
        }

        let wrongFormatVersion = """
        {"formatVersion":2,"runtimeRoot":"/Users/test/.acp-gateway/runtime/versions/1.3.1-abcdef","gatewayVersion":"1.3.1","gatewayBuildId":"abcdef"}
        """
        guard BundledRuntime.parseCurrentRuntime(data: Data(wrongFormatVersion.utf8)) == nil else {
            throw CheckError.failed("expected an unsupported current.json formatVersion to be rejected")
        }

        guard BundledRuntime.parseCurrentRuntime(data: Data("not json".utf8)) == nil else {
            throw CheckError.failed("expected non-JSON current.json content to be rejected")
        }
    }

    static func checkRuntimeProvisionerResultParsing() throws {
        let valid = """
        {"runtimeRoot":"/Users/test/.acp-gateway/runtime/versions/1.3.1-abcdef","gatewayVersion":"1.3.1","gatewayBuildId":"abcdef"}
        """
        guard let info = RuntimeProvisioner.parse(valid) else {
            throw CheckError.failed("expected a well-formed runtime-installer-cli.js result to parse")
        }
        guard info.runtimeRoot == "/Users/test/.acp-gateway/runtime/versions/1.3.1-abcdef" else {
            throw CheckError.failed("expected the parsed runtimeRoot to round-trip exactly")
        }

        guard RuntimeProvisioner.parse("not json") == nil else {
            throw CheckError.failed("expected unparseable runtime-installer-cli.js output to return nil")
        }
        guard RuntimeProvisioner.parse("{}") == nil else {
            throw CheckError.failed("expected output missing required fields to return nil")
        }
    }
}

private enum CheckError: Error {
    case failed(String)
}
