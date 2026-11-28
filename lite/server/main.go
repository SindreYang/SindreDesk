//go:build linux && amd64

package main

import (
    "context"
    "crypto/sha256"
    "crypto/x509"
    "embed"
    "encoding/base64"
    "encoding/hex"
    "encoding/json"
    "encoding/pem"
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

// serverInfo 仅导出客户端连接所需的公开信息。证书 SAN 是配置的 IP，不代表公网探测结果。
func serverInfo(dir string) error {
    key, err := publicKey(dir)
    if err != nil { return fmt.Errorf("请先启动服务生成公钥: %w", err) }
    certPEM, err := os.ReadFile(filepath.Join(dir, "api.crt"))
    if err != nil { return fmt.Errorf("请先启动服务生成 HTTPS 证书: %w", err) }
    block, _ := pem.Decode(certPEM)
    if block == nil || block.Type != "CERTIFICATE" { return errors.New("HTTPS 公共证书格式无效") }
    cert, err := x509.ParseCertificate(block.Bytes)
    if err != nil { return err }
    if len(cert.IPAddresses) != 1 { return errors.New("HTTPS 证书必须包含一个明确的服务端 IP") }
    ip := cert.IPAddresses[0].String()
    digest := sha256.Sum256(cert.Raw)
    info := struct {
        IP string `json:"ip"`
        IDServer string `json:"id_server"`
        RelayServer string `json:"relay_server_default"`
        APIURL string `json:"api_url"`
        RustDeskKey string `json:"rustdesk_key"`
        TLSCertificate string `json:"tls_certificate"`
        TLSSHA256 string `json:"tls_sha256"`
    }{
        IP: ip,
        IDServer: net.JoinHostPort(ip, "22116"),
        RelayServer: net.JoinHostPort(ip, "22117"),
        APIURL: "https://" + net.JoinHostPort(ip, "22120"),
        RustDeskKey: key,
        TLSCertificate: string(certPEM),
        TLSSHA256: hex.EncodeToString(digest[:]),
    }
    encoder := json.NewEncoder(os.Stdout)
    encoder.SetIndent("", "  ")
    return encoder.Encode(info)
}

func stateDir() (string, error) {
    p, err := os.Executable()
    if err != nil { return "", err }
    p, err = filepath.EvalSymlinks(p)
    if err != nil { return "", err }
    return filepath.Join(filepath.Dir(p), "SindreDeskLiteData"), nil
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
    if len(os.Args) == 2 && os.Args[1] == "info" { return serverInfo(dir) }
    if len(os.Args) == 2 && os.Args[1] == "cert" {
        b, err := os.ReadFile(filepath.Join(dir, "api.crt")); if err != nil { return err }; fmt.Print(string(b)); return nil
    }
    if len(os.Args) == 2 && os.Args[1] == "key" {
        key, err := publicKey(dir)
        if err != nil { return err }
        fmt.Println(key)
        return nil
    }
    if len(os.Args) == 2 && os.Args[1] == "status" {
        lock, err := os.OpenFile(filepath.Join(dir, ".lock"), os.O_RDONLY|syscall.O_NOFOLLOW, 0600)
        if err != nil { return fmt.Errorf("服务未运行: %w", err) }
        defer lock.Close()
        err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
        if err == nil {
            syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
            return errors.New("服务未运行")
        }
        if !errors.Is(err, syscall.EWOULDBLOCK) { return err }
        if !portsReady() { return errors.New("服务进程存在，但 TCP 端口未就绪") }
        conn, err := net.DialTimeout("tcp", "127.0.0.1:22120", time.Second)
        if err != nil { return errors.New("设备码 HTTPS 端口未就绪") }; conn.Close()
        fmt.Println("服务运行中；TCP 22115–22117 / 22120 可达（非协议认证测试）")
        return nil
    }
    if len(os.Args) != 1 { return errors.New("用法: SindreDeskLiteServer [info|key|cert|status]") }
    lock, err := os.OpenFile(filepath.Join(dir, ".lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
    if err != nil { return err }
    defer lock.Close()
    if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil { return fmt.Errorf("无法获取数据目录锁: %w", err) }
    defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
    // 启动前拒绝已占用端口，避免误把其他实例当成本次启动结果。
    if err := checkPortsAvailable(); err != nil { return err }
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
    args := []string{"-k", "_", "-p", "22116", "-r", "43.138.240.23:22117"}
    if relay := strings.TrimSpace(os.Getenv("SINDREDESK_RELAY")); relay != "" { args[5] = relay }
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
    if err := start(ctx, hbbr, dir, results, "-k", "_", "-p", "22117"); err != nil { return err }
    running++
    readyDeadline := time.NewTimer(20*time.Second)
    defer readyDeadline.Stop()
    for !portsReady() {
        select {
        case <-ctx.Done(): return nil
        case r := <-results:
            running--
            return fmt.Errorf("%s 提前退出: %v", r.name, r.err)
        case <-readyDeadline.C: return errors.New("等待 TCP 22115–22117 就绪超时")
        case <-tick.C:
        }
    }
    api, err := startAPI(dir)
    if err != nil { return err }
    defer api.close()
    fmt.Println("服务端公钥:", key)
    fmt.Println("数据目录:", dir)
    fmt.Println("TCP 22115–22117 已就绪；等待连接")
    select {
    case <-ctx.Done(): return nil
    case e := <-api.done: return fmt.Errorf("设备码服务退出: %w", e)
    case r := <-results:
        running--
        return fmt.Errorf("%s 退出: %v", r.name, r.err)
    }
}

func portsReady() bool {
    for _, port := range []string{"22115", "22116", "22117"} {
        conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), 150*time.Millisecond)
        if err != nil { return false }
        conn.Close()
    }
    return true
}

func main() {
    if len(os.Args) == 2 && os.Args[1] == "install" { if err := installService(); err != nil { log.Fatal(err) }; return }
    if err := run(); err != nil { log.Fatal(err) }
}

// checkPortsAvailable 仅作启动前检查；实际绑定仍由子进程完成。
func checkPortsAvailable() error {
    for _, port := range []string{"22115", "22116", "22117", "22118", "22119", "22120"} {
        listener, err := net.Listen("tcp", ":"+port)
        if err != nil { return fmt.Errorf("TCP %s 不可用: %w", port, err) }
        listener.Close()
    }
    listener, err := net.ListenPacket("udp", ":22116")
    if err != nil { return fmt.Errorf("UDP 22116 不可用: %w", err) }
    return listener.Close()
}
