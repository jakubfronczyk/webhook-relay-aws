// Package migrations carries the schema into the binary, so a fresh database
// needs no migration container or init job.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
