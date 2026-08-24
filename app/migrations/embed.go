// Package migrations carries the schema into the binary.
//
// Embedding is the reason there is no migration container and no init job: the
// api and the worker both apply the schema on startup, so a fresh RDS instance
// is usable the moment the first task passes its health check.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
