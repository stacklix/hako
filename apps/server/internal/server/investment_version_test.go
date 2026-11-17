package server

import (
	"encoding/json"
	"net/http"
	"strconv"
	"testing"
)

func TestInvestmentVersionRequiresConsoleAndReportsLiveSchema(t *testing.T) {
	f := newFixture(t, true)
	const path = "/api/v1/investment/version"
	response, err := f.http.Client().Get(f.http.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated version query = %d", response.StatusCode)
	}
	for _, actual := range []int{5, 4, 6} {
		if _, err := f.s.investment.Exec("PRAGMA user_version = " + strconv.Itoa(actual)); err != nil {
			t.Fatal(err)
		}
		status, body := f.call(http.MethodGet, path, nil, f.tokens.AccessToken)
		var result map[string]int
		if err := json.Unmarshal(body, &result); err != nil || status != http.StatusOK {
			t.Fatalf("version response = %d %s (%v)", status, body, err)
		}
		if len(result) != 2 || result["version"] != actual || result["expectedVersion"] != investmentSchemaVersion {
			t.Fatalf("actual and expected versions conflated: %v", result)
		}
		var after int
		if err := f.s.investment.QueryRow("PRAGMA user_version").Scan(&after); err != nil || after != actual {
			t.Fatalf("read changed database version: %d (%v)", after, err)
		}
	}
}

func TestInvestmentVersionDoesNotReportSuccessOnReadFailure(t *testing.T) {
	f := newFixture(t, true)
	if err := f.s.investment.Close(); err != nil {
		t.Fatal(err)
	}
	if status, body := f.call(http.MethodGet, "/api/v1/investment/version", nil, f.tokens.AccessToken); status != http.StatusInternalServerError {
		t.Fatalf("unreadable version = %d %s", status, body)
	}
}
