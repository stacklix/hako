package server

import (
	"context"
	"database/sql"
	"math/big"
)

// Investment is a separate SQLite database with its own schema version.
const investmentSchemaVersion = 10

const investmentAccountTypesSQL = "'securities','fund_wealth','futures','deposits','crypto','insurance'"

func finalInvestmentFX(row investmentRow) bool {
	if row["is_final"] != "1" {
		return false
	}
	rate, ok := new(big.Rat).SetString(row["rate"])
	return ok && rate.Sign() > 0
}

func equalInvestmentNumber(left, right string) bool {
	a, aOK := new(big.Rat).SetString(left)
	b, bOK := new(big.Rat).SetString(right)
	return aOK && bOK && a.Cmp(b) == 0
}

func investmentChangesCount(ctx context.Context, tx *sql.Tx) (int64, error) {
	var count int64
	err := tx.QueryRowContext(ctx, "SELECT total_changes()").Scan(&count)
	return count, err
}

func earliestMarketDate(rows []investmentRow) string {
	first := ""
	for _, row := range rows {
		day := row["rate_date"]
		if day == "" {
			day = row["valuation_date"]
		}
		if day == "" {
			day = row["session_date"]
		}
		if day != "" && (first == "" || day < first) {
			first = day
		}
	}
	return first
}

// Shared FX can change every ledger's valuation, including ledgers that did
// not make the request. Leave the caller's metadata to its normal transaction.
func invalidateSharedFX(ctx context.Context, tx *sql.Tx, caller, from string) error {
	_, err := tx.ExecContext(ctx, `UPDATE investment_books SET revision=revision+1,
		snapshot_dirty_from=CASE WHEN snapshot_dirty_from IS NULL OR snapshot_dirty_from>? THEN ? ELSE snapshot_dirty_from END
		WHERE id<>?`, from, from, caller)
	return err
}
