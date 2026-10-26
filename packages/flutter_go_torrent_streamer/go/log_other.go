//go:build !android

package main

import (
	"fmt"
	"os"
)

// Log writes to standard error. A Windows GUI process has none attached,
// so release builds show nothing; it is for runs from a console.
func Log(msg string) {
	fmt.Fprintln(os.Stderr, msg)
}
