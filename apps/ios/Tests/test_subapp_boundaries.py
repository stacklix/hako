"""Keep child business code out of the shell and out of sibling features."""
from pathlib import Path
import re
import shlex
import unittest

APP = Path(__file__).resolve().parents[1] / "Hako"
REPO = APP.parents[2]
FEATURES = APP / "Features"


class SubappBoundariesTests(unittest.TestCase):
    @staticmethod
    def feature_types():
        owners = {}
        declarations = re.compile(
            r"^(?:(?:@\w+(?:\([^\n]*?\))?|public|internal|private|fileprivate|final|indirect|nonisolated)\s+)*"
            r"(?:class|struct|enum|protocol|typealias|actor)\s+(\w+)", re.M)
        for path in FEATURES.rglob("*.swift"):
            feature = path.relative_to(FEATURES).parts[0]
            for name in declarations.findall(path.read_text(encoding="utf-8")):
                owners.setdefault(name, set()).add(feature)
        return owners

    def test_subapps_do_not_reference_sibling_types(self):
        # ServerManagement and Notifications provide host UI rather than child apps.
        host_features = {"ServerManagement", "Notifications"}
        owners = self.feature_types()
        for path in FEATURES.rglob("*.swift"):
            feature = path.relative_to(FEATURES).parts[0]
            if feature in host_features:
                continue
            source = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
            for name in set(re.findall(r"\b\w+\b", source)):
                targets = owners.get(name, set())
                if len(targets) == 1:
                    self.assertFalse(targets - host_features - {feature},
                                     f"{path.relative_to(APP)} references sibling type {name}")

    def test_shared_ui_does_not_reference_feature_types(self):
        owners = self.feature_types()
        for path in (APP / "Shared/UI").glob("*.swift"):
            source = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
            for name in set(re.findall(r"\b\w+\b", source)):
                self.assertNotIn(name, owners,
                                 f"{path.relative_to(APP)} references feature type {name}")

    def test_investment_navigation_does_not_push_values_into_the_home_path(self):
        for path in (FEATURES / "Investment").glob("*.swift"):
            source = path.read_text(encoding="utf-8")
            self.assertNotRegex(source, r"\bNavigationLink\s*\([^)]*\bvalue\s*:", path.name)
            self.assertNotIn("navigationDestination(for: InvestmentRoute.self", source, path.name)

    def test_shell_only_registers_usage_entry(self):
        shell = (APP / "App/HakoApp.swift").read_text(encoding="utf-8")
        catalog = (APP / "App/HakoApplications.swift").read_text(encoding="utf-8")
        self.assertIn("HakoApplications.Application", shell)
        self.assertIn("UsageEntry()", catalog)
        for feature in ("DailyUsage", "UsageView", "Database", "FamilyControls", "ManagedSettings", "SwiftData", "modelContainer"):
            self.assertNotIn(feature, shell + catalog)

    def test_usage_owns_lazy_database_and_business_files(self):
        view = (APP / "Features/Usage/UsageView.swift").read_text(encoding="utf-8")
        self.assertIn("UsageDatabase.shared", view)
        self.assertIn("UsageView().modelContainer(container)", view)
        for name in ("UsageModels.swift", "UsageRecorder.swift", "ScreenTime.swift", "UsageSync.swift", "UsageCSV.swift", "UsageGitHub.swift"):
            self.assertTrue((FEATURES / "Usage" / name).is_file(), name)
        for name in ("Models.swift", "Recorder.swift", "ScreenTime.swift", "UsageSync.swift"):
            self.assertFalse((APP / name).exists(), name)
            self.assertFalse((APP / "App" / name).exists(), name)

    def test_shortcuts_have_one_host_action_and_child_owned_registrations(self):
        host = (APP / "App/HakoShortcuts.swift").read_text(encoding="utf-8")
        catalog = (APP / "App/HakoApplications.swift").read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"\bAppShortcut\s*\(", host)), 1)
        self.assertNotRegex(host, r"\b(UsageShortcutContributor|CryptoShortcutContributor|Recorder|CryptoStore)\b")
        self.assertIn("HakoApplications.registerShortcuts(in: registry)", host)
        self.assertNotIn("import ObjectiveC", host)
        self.assertIn("Category.allCases.flatMap(\\.applications)", catalog)
        for folder in ("Usage", "Crypto", "Investment"):
            self.assertIn(f"{folder}ShortcutContributor.registerShortcuts(in: registry)", catalog)
            sources = "\n".join(path.read_text(encoding="utf-8") for path in (FEATURES / folder).glob("*.swift"))
            self.assertNotIn("import AppIntents", sources)
            self.assertIn(f"enum {folder}ShortcutContributor", sources)
            self.assertIn("registry.register(", sources)

    def test_common_code_contains_no_child_business_types(self):
        for name in ("Shared/GitHub/GitHubRepository.swift", "Shared/GitHub/GitHubService.swift", "App/AppServices.swift", "Shared/GitHub/GitHubSettings.swift", "Shared/GitHub/GitHubTokenStore.swift", "Shared/Infrastructure/CSV.swift", "Shared/Infrastructure/HakoError.swift"):
            source = (APP / name).read_text(encoding="utf-8")
            self.assertIsNone(re.search(r"\b(DailyUsage|UsageDay|UsageMerge|SportsRecord|SportsMerge|ScreenTime)\b", source), name)

    def test_child_github_access_uses_host_contract_only(self):
        forbidden = r"\b(TokenStore|GitHubSettings|GitHubService|GitHubClient|URLSession)\b|api\.github\.com|createCommitOnBranch|query Hako"
        for feature in ("Sports", "Usage"):
            for path in (FEATURES / feature).glob("*.swift"):
                self.assertIsNone(re.search(forbidden, path.read_text(encoding="utf-8")), str(path))
        contract = (APP / "Shared/GitHub/GitHubRepository.swift").read_text(encoding="utf-8")
        self.assertIn("protocol GitHubRepositoryAccess", contract)
        self.assertNotIn("token", contract.lower())

    def test_siblings_do_not_reference_each_others_business_types(self):
        for path in (FEATURES / "Sports").glob("*.swift"):
            self.assertIsNone(re.search(r"\b(DailyUsage|UsageDay|UsageMerge|UsageSync|Recorder|ScreenTime)\b", path.read_text(encoding="utf-8")), path.name)
        for path in (FEATURES / "Usage").glob("*.swift"):
            self.assertIsNone(re.search(r"\b(SportsRecord|SportsState|SportsStore|SportsMerge|SportsView)\b", path.read_text(encoding="utf-8")), path.name)

    def test_shared_auth_transport_has_no_monitoring_or_ecs_business(self):
        source = (APP / "Shared/HakoServer/ConsoleClient.swift").read_text(encoding="utf-8")
        for feature in ("ConsoleAgent", "ConsoleDeviceData", "ConsoleHTTPCheckState", "ECSAccessRange", "ECSAccessQuery", "func fetchAgents", "func addAgent", "func accessLogs", '"/api/v1/agents'):
            self.assertNotIn(feature, source)
        self.assertIn("func authorized(", source)
        self.assertTrue((APP / "Features/DeviceManagement/DeviceMonitorClient.swift").is_file())
        self.assertTrue((APP / "Features/CloudServers/ECSAccessClient.swift").is_file())

    def test_ci_compiler_sources_still_exist(self):
        workflow = (REPO / ".github/workflows/ios.yml").read_text(encoding="utf-8")
        for line in workflow.splitlines():
            if line.strip().startswith("swiftc "):
                for token in shlex.split(line.strip()):
                    if token.endswith(".swift"):
                        self.assertTrue((APP.parent / token).is_file(), token)

    def test_children_use_server_contract_without_concrete_client_extensions(self):
        for folder in ("DeviceManagement", "CloudServers"):
            for path in (FEATURES / folder).glob("*.swift"):
                self.assertNotIn("ConsoleClient", path.read_text(encoding="utf-8"), path.name)
        for name in ("Features/DeviceManagement/DeviceMonitorClient.swift", "Features/CloudServers/ECSAccessClient.swift"):
            self.assertIn("any AuthenticatedServerAccess", (APP / name).read_text(encoding="utf-8"))

    def test_child_keychains_delegate_to_host_and_keep_schema_validation(self):
        for name, validation in (("Features/Containers/ArcaneKeychain.swift", "normalized()"), ("Features/CloudServers/ECSKeychain.swift", "validated()")):
            source = (APP / name).read_text(encoding="utf-8")
            self.assertIn("any SecretStorage", source)
            self.assertIn(validation, source)
            self.assertNotIn("import Security", source)
            self.assertNotIn("SecItem", source)

    def test_credential_network_policy_is_owned_by_host(self):
        for name in ("Features/Containers/ArcaneClient.swift", "Features/CloudServers/ECSRPC.swift", "Shared/HakoServer/ConsoleClient.swift", "Features/Headplane/HeadplaneClient.swift"):
            source = (APP / name).read_text(encoding="utf-8")
            self.assertIn("HTTPTransport.makeSession", source)
            self.assertNotIn("URLSessionConfiguration", source)
            self.assertNotIn("willPerformHTTPRedirection", source)

    def test_headplane_is_independent_of_other_subapps(self):
        for path in (FEATURES / "Headplane").glob("*.swift"):
            self.assertIsNone(re.search(r"\b(ConsoleClient|ArcaneClient|QinglongClient|GitHubService|ECSStore|SecItemCopyMatching)\b", path.read_text(encoding="utf-8")), path.name)
        store = (APP / "Features/Headplane/HeadplaneStore.swift").read_text(encoding="utf-8")
        self.assertIn('SecureStorage.namespace("me.stackli.hako.headplane")', store)
        self.assertIn("any HeadplaneAccess", store)
        self.assertIn("any SecretStorage", store)


if __name__ == "__main__":
    unittest.main()
