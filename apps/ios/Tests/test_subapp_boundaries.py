"""Keep child business code out of the shell and out of sibling features."""
from pathlib import Path
import re
import shlex
import unittest

APP = Path(__file__).resolve().parents[1] / "Hako"
REPO = APP.parents[2]


class SubappBoundariesTests(unittest.TestCase):
    def test_shell_only_registers_usage_entry(self):
        shell = (APP / "HakoApp.swift").read_text(encoding="utf-8")
        self.assertIn("UsageEntry()", shell)
        for feature in ("DailyUsage", "UsageView", "Database", "FamilyControls", "ManagedSettings", "SwiftData", "modelContainer"):
            self.assertNotIn(feature, shell)

    def test_usage_owns_lazy_database_and_business_files(self):
        view = (APP / "Usage/UsageView.swift").read_text(encoding="utf-8")
        self.assertIn("UsageDatabase.shared", view)
        self.assertIn("UsageView().modelContainer(container)", view)
        for name in ("UsageModels.swift", "UsageRecorder.swift", "ScreenTime.swift", "UsageSync.swift", "UsageCSV.swift", "UsageGitHub.swift"):
            self.assertTrue((APP / "Usage" / name).is_file(), name)
        for name in ("Models.swift", "Recorder.swift", "ScreenTime.swift", "UsageSync.swift"):
            self.assertFalse((APP / name).exists(), name)

    def test_common_code_contains_no_child_business_types(self):
        for name in ("GitHubRepository.swift", "GitHubService.swift", "AppServices.swift", "GitHubSettings.swift", "GitHubTokenStore.swift", "CSV.swift", "HakoError.swift"):
            source = (APP / name).read_text(encoding="utf-8")
            self.assertIsNone(re.search(r"\b(DailyUsage|UsageDay|UsageMerge|SportsRecord|SportsMerge|ScreenTime)\b", source), name)

    def test_child_github_access_uses_host_contract_only(self):
        forbidden = r"\b(TokenStore|GitHubSettings|GitHubService|GitHubClient|URLSession)\b|api\.github\.com|createCommitOnBranch|query Hako"
        for feature in ("Sports", "Usage"):
            for path in (APP / feature).glob("*.swift"):
                self.assertIsNone(re.search(forbidden, path.read_text(encoding="utf-8")), str(path))
        contract = (APP / "GitHubRepository.swift").read_text(encoding="utf-8")
        self.assertIn("protocol GitHubRepositoryAccess", contract)
        self.assertNotIn("token", contract.lower())

    def test_siblings_do_not_reference_each_others_business_types(self):
        for path in (APP / "Sports").glob("*.swift"):
            self.assertIsNone(re.search(r"\b(DailyUsage|UsageDay|UsageMerge|UsageSync|Recorder|ScreenTime)\b", path.read_text(encoding="utf-8")), path.name)
        for path in (APP / "Usage").glob("*.swift"):
            self.assertIsNone(re.search(r"\b(SportsRecord|SportsState|SportsStore|SportsMerge|SportsView)\b", path.read_text(encoding="utf-8")), path.name)

    def test_shared_auth_transport_has_no_monitoring_or_ecs_business(self):
        source = (APP / "Server/ConsoleClient.swift").read_text(encoding="utf-8")
        for feature in ("ConsoleAgent", "ConsoleDeviceData", "ConsoleHTTPCheckState", "ECSAccessRange", "ECSAccessQuery", "func fetchAgents", "func addAgent", "func accessLogs", '"/api/v1/agents'):
            self.assertNotIn(feature, source)
        self.assertIn("func authorized(", source)
        self.assertTrue((APP / "DeviceManagement/DeviceMonitorClient.swift").is_file())
        self.assertTrue((APP / "CloudServers/ECSAccessClient.swift").is_file())

    def test_ci_compiler_sources_still_exist(self):
        workflow = (REPO / ".github/workflows/ios.yml").read_text(encoding="utf-8")
        for line in workflow.splitlines():
            if line.strip().startswith("swiftc "):
                for token in shlex.split(line.strip()):
                    if token.endswith(".swift"):
                        self.assertTrue((APP.parent / token).is_file(), token)

    def test_children_use_server_contract_without_concrete_client_extensions(self):
        for folder in ("DeviceManagement", "CloudServers"):
            for path in (APP / folder).glob("*.swift"):
                self.assertNotIn("ConsoleClient", path.read_text(encoding="utf-8"), path.name)
        for name in ("DeviceManagement/DeviceMonitorClient.swift", "CloudServers/ECSAccessClient.swift"):
            self.assertIn("any AuthenticatedServerAccess", (APP / name).read_text(encoding="utf-8"))

    def test_child_keychains_delegate_to_host_and_keep_schema_validation(self):
        for name, validation in (("Containers/ArcaneKeychain.swift", "normalized()"), ("CloudServers/ECSKeychain.swift", "validated()")):
            source = (APP / name).read_text(encoding="utf-8")
            self.assertIn("any SecretStorage", source)
            self.assertIn(validation, source)
            self.assertNotIn("import Security", source)
            self.assertNotIn("SecItem", source)

    def test_credential_network_policy_is_owned_by_host(self):
        for name in ("Containers/ArcaneClient.swift", "CloudServers/ECSRPC.swift", "Server/ConsoleClient.swift"):
            source = (APP / name).read_text(encoding="utf-8")
            self.assertIn("HTTPTransport.makeSession", source)
            self.assertNotIn("URLSessionConfiguration", source)
            self.assertNotIn("willPerformHTTPRedirection", source)


if __name__ == "__main__":
    unittest.main()
