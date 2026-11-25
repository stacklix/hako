import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class InvestmentWriteContractTests(unittest.TestCase):
    def test_client_rules_match_server_contract(self):
        server = (ROOT / "apps/server/internal/server/investment.go").read_text(encoding="utf-8")
        client = (ROOT / "apps/ios/Hako/Features/Investment/InvestmentWriteValidation.swift").read_text(encoding="utf-8")
        tables = {
            name: (keys, fields, output)
            for name, keys, fields, output in re.findall(r'\{"(\w+)", "([^"]+)", "([^"]+)", (true|false)\}', server)
        }
        local = {
            name: (keys, fields, output)
            for name, keys, fields, required, output in re.findall(
                r'"(\w+)": \.init\(keys: "([^"]+)", fields: "([^"]+)", required: "([^"]*)", output: (true|false)\)', client
            )
        }
        self.assertEqual(tables, local)
        required_block = server.split("var investmentRequired", 1)[1].split("type investmentState", 1)[0]
        required = dict(re.findall(r'"(\w+)":\s+"([^"]+)"', required_block))
        local_required = dict(re.findall(r'"(\w+)": \.init\([^\n]+required: "([^"]*)"', client))
        self.assertEqual({name: required.get(name, "") for name in tables}, local_required)
        link_block = server.split("func validateInvestmentLinks", 1)[1].split("\n\t} {", 1)[0]
        server_links = set(re.findall(r'\{"(\w+)", "(\w+)", "(\w+)", "(\w+)"\}', link_block))
        client_links = set(re.findall(r'\("(\w+)", "(\w+)", "(\w+)", "(\w+)"\)', client))
        self.assertEqual(server_links, client_links)
        for server_name, client_name in [("investmentNumberFields", "numbers"), ("investmentIntegerFields", "integers")]:
            remote = re.search(server_name + r' = "([^"]+)"', server)[1].split()
            local_fields = re.search("static let " + client_name + r' = Set\("([^"]+)"', client)[1].split()
            self.assertEqual(set(remote), set(local_fields))


if __name__ == "__main__":
    unittest.main()
