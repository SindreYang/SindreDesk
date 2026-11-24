//go:build linux && amd64

package main

import (
    "encoding/base64"
    "os"
    "net"
    "path/filepath"
    "testing"
)

func TestPublicKey(t *testing.T) {
    dir := t.TempDir()
    if _, err := publicKey(dir); err == nil { t.Fatal("missing key accepted") }
    key := base64.StdEncoding.EncodeToString(make([]byte, 32))
    path := filepath.Join(dir, "id_ed25519.pub")
    if err := os.WriteFile(path, []byte(key+"\n"), 0600); err != nil { t.Fatal(err) }
    if got, err := publicKey(dir); err != nil || got != key { t.Fatalf("valid key rejected: %v", err) }
    if err := os.WriteFile(path, []byte("invalid"), 0600); err != nil { t.Fatal(err) }
    if _, err := publicKey(dir); err == nil { t.Fatal("invalid key accepted") }
}

func TestMissingPayload(t *testing.T) {
    if _, err := extract(t.TempDir(), "nonexistent"); err == nil { t.Fatal("missing payload accepted") }
}

func TestStateDir(t *testing.T) {
    dir := t.TempDir()
    t.Setenv("SINDREDESK_DATA_DIR", dir)
    if got, err := stateDir(); err != nil || got != dir { t.Fatalf("unexpected data dir: %q %v", got, err) }
}

func TestOccupiedPort(t *testing.T) {
    listener, err := net.Listen("tcp", ":21115")
    if err != nil { t.Skip("test port already occupied") }
    defer listener.Close()
    if err := checkPortsAvailable(); err == nil { t.Fatal("occupied port accepted") }
}
