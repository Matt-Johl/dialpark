// Package diag receives diagnostics from devices — app and extension logs,
// MetricKit crash/CPU/hang reports, iOS crash files — and stores them on the
// server's disk, where whoever is debugging can read them without pulling
// anything off the phone. Development aid; token-protected like the
// directory API.
package diag

import (
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// MaxBytes bounds one upload.
const MaxBytes = 8 << 20

// Handler serves POST /v1/diag: the body is stored verbatim under
// <dir>/<device>/<UTC time>-<kind>[-<name>].<ext>. Headers: X-Diag-Kind
// (app-log, extension-log, intents-log, metrickit, ips, …; required), X-Diag-Name
// (optional). The device id comes from X-Device-ID, verified by deviceAuth.
func Handler(dir string, deviceAuth func(http.Handler) http.Handler, log *slog.Logger) http.Handler {
	if log == nil {
		log = slog.Default()
	}
	return deviceAuth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		device := clean(r.Header.Get("X-Device-ID"))
		kind := clean(r.Header.Get("X-Diag-Kind"))
		name := clean(r.Header.Get("X-Diag-Name"))
		if device == "" || kind == "" {
			http.Error(w, "X-Device-ID and X-Diag-Kind required", http.StatusBadRequest)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBytes))
		if err != nil {
			http.Error(w, "body too large or unreadable", http.StatusRequestEntityTooLarge)
			return
		}
		path, err := Store(dir, device, kind, name, body)
		if err != nil {
			log.Error("diag: store failed", "device", device, "kind", kind, "err", err)
			http.Error(w, "store failed", http.StatusInternalServerError)
			return
		}
		log.Info("diag received", "device", device, "kind", kind, "name", name, "bytes", len(body), "path", path)
		w.WriteHeader(http.StatusNoContent)
	}))
}

// Purge removes everything a device uploaded (an admin purging the device,
// ADMIN-API.md §5.1). A device that never uploaded is not an error.
func Purge(dir, device string) error {
	device = clean(device)
	if device == "" {
		return nil
	}
	err := os.RemoveAll(filepath.Join(dir, device))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// Store writes one diagnostic and returns its path.
func Store(dir, device, kind, name string, body []byte) (string, error) {
	d := filepath.Join(dir, device)
	if err := os.MkdirAll(d, 0o755); err != nil {
		return "", err
	}
	base := time.Now().UTC().Format("20060102T150405.000Z") + "-" + kind
	if name != "" {
		base += "-" + name
	}
	path := filepath.Join(d, base+ext(kind, name))
	return path, os.WriteFile(path, body, 0o644)
}

func ext(kind, name string) string {
	switch {
	case strings.HasSuffix(name, ".ips") || kind == "ips":
		return ".ips"
	case kind == "metrickit" || strings.HasSuffix(name, ".json"):
		return ".json"
	case strings.HasSuffix(kind, "log"):
		return ".log"
	}
	return ".txt"
}

// clean keeps a header value safe as a path component.
func clean(s string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(s) {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_', r == '.':
			b.WriteRune(r)
		}
	}
	out := strings.Trim(b.String(), ".")
	if len(out) > 80 {
		out = out[:80]
	}
	return fmt.Sprint(out)
}
