//go:build linux && amd64

package main

import (
    "context"
    "embed"
    "encoding/base64"
    "errors"
    "fmt"
    "log"
    "net"
    "os"
    "os/exec"
    "os/signal"
    "path/filepath"
    "strings"
    "syscall"
    "time"
)

//go:embed payload/*
var payload embed.FS

func publicKey(dir string) (string, error) {
    b, err := os.ReadFile(filepath.Join(dir, "id_ed25519.pub"))
    if err != nil { return "", err }
    key := strings.TrimSpace(string(b))
    raw, err := base64.StdEncoding.DecodeString(key)
    if err != nil || len(raw) != 32 { return "", errors.New("服务端公钥格式无效") }
    return key, nil
}

func stateDir() (string, error) {
    if p := os.Getenv("SINDREDESK_DATA_DIR"); p != "" { return filepath.Abs(p) }
    p, err := os.UserConfigDir()
    if err != nil { return "", err }
    return filepath.Join(p, "sindredesk-server"), nil
}

func extract(dir, name string) (string, error) {
    data, err := payload.ReadFile("payload/" + name)
    if err != nil { return "", fmt.Errorf("缺少内嵌 %s，请使用 build-server.sh 构建: %w", name, err) }
    p := filepath.Join(dir, name)
    if err := os.WriteFile(p, data, 0700); err != nil { return "", err }
    return p, nil
}

type childResult struct { name string; err error }

func start(ctx context.Context, path, dir string, results chan<- childResult, args ...string) error {
    cmd := exec.CommandContext(ctx, path, args...)
    cmd.Dir = dir
    cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
    cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
    cmd.WaitDelay = 5*time.Second
    if err := cmd.Start(); err != nil { return err }
    go func() { results <- childResult{filepath.Base(path), cmd.Wait()} }()
    return nil
}

func run() error {
    dir, err := stateDir()
    if err != nil { return err }
    syscall.Umask(0077)
    if err := os.MkdirAll(dir, 0700); err != nil { return err }
    info, err := os.Lstat(dir)
    if err != nil { return err }
    if !info.IsDir() || info.Mode().Perm() & 0077 != 0 { return errors.New("数据目录必须为非符号链接且权限为 0700 或更严格") }
    if len(os.Args) == 2 && os.Args[1] == "key" {
        key, err := publicKey(dir)
        if err != nil { return err }
        fmt.Println(key)
        return nil
    }
    if len(os.Args) != 1 { return errors.New("用法: SindreDeskServer [key]") }
    lock, err := os.OpenFile(filepath.Join(dir, ".lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
    if err != nil { return err }
    defer lock.Close()
    if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil { return fmt.Errorf("无法获取数据目录锁: %w", err) }
    defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
    // 在私有目录释放二进制，避免覆盖持久密钥及数据库。
    bin, err := os.MkdirTemp(dir, ".bin-")
    if err != nil { return err }
    defer os.RemoveAll(bin)
    hbbs, err := extract(bin, "hbbs")
    if err != nil { return err }
    hbbr, err := extract(bin, "hbbr")
    if err != nil { return err }
    ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer stop()
    ctx, cancel := context.WithCancel(ctx)
    results := make(chan childResult, 2)
    running := 0
    defer func() {
        cancel()
        for running > 0 { <-results; running-- }
    }()
    // 上游 hbbs 首次启动生成密钥；强制客户端密钥校验。
    args := []string{"-k", "_"}
    if relay := strings.TrimSpace(os.Getenv("SINDREDESK_RELAY")); relay != "" { args = append(args, "-r", relay) }
    if err := start(ctx, hbbs, dir, results, args...); err != nil { return err }
    running++
    timeout := time.NewTimer(20*time.Second)
    defer timeout.Stop()
    tick := time.NewTicker(100*time.Millisecond)
    defer tick.Stop()
    var key string
    for key == "" {
        select {
        case <-ctx.Done(): return nil
        case r := <-results:
            running--
            return fmt.Errorf("%s 提前退出: %v", r.name, r.err)
        case <-timeout.C: return errors.New("等待服务端公钥超时")
        case <-tick.C:
            key, _ = publicKey(dir)
        }
    }
    if err := start(ctx, hbbr, dir, results, "-k", "_"); err != nil { return err }
    running++
    readyDeadline := time.NewTimer(20*time.Second)
    defer readyDeadline.Stop()
    for !portsReady() {
        select {
        case <-ctx.Done(): return nil
        case r := <-results:
            running--
            return fmt.Errorf("%s 提前退出: %v", r.name, r.err)
        case <-readyDeadline.C: return errors.New("等待 TCP 21115–21117 就绪超时")
        case <-tick.C:
        }
    }
    fmt.Println("服务端公钥:", key)
    fmt.Println("数据目录:", dir)
    fmt.Println("TCP 21115–21117 已就绪；等待连接")
    select {
    case <-ctx.Done(): return nil
    case r := <-results:
        running--
        return fmt.Errorf("%s 退出: %v", r.name, r.err)
    }
}

func portsReady() bool {
    for _, port := range []string{"21115", "21116", "21117"} {
        conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), 150*time.Millisecond)
        if err != nil { return false }
        conn.Close()
    }
    return true
}

func main() {
    if err := run(); err != nil { log.Fatal(err) }
}
