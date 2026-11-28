//go:build linux && amd64

package main

import (
    "errors"
    "fmt"
    "os"
    "os/exec"
    "os/user"
    "path/filepath"
    "strconv"
    "strings"
    "syscall"
)

const unitPath = "/etc/systemd/system/sindredesk-lite.service"

func systemctl(args ...string) error {
    cmd := exec.Command("systemctl", args...)
    cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
    return cmd.Run()
}

// systemd 中百分号会触发 specifier 展开，ExecStart 中美元符号会触发环境变量展开。
func unitQuote(path string) (string, error) {
    if strings.ContainsAny(path, "\n\r\x00\t$") {
        return "", errors.New("安装路径不能含控制字符或美元符号")
    }
    return "\"" + strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "%", "%%").Replace(path) + "\"", nil
}

func serviceAccount(info os.FileInfo) (*user.User, error) {
    stat, ok := info.Sys().(*syscall.Stat_t)
    if !ok { return nil, errors.New("无法读取程序属主") }
    if stat.Uid != 0 {
        return user.LookupId(strconv.FormatUint(uint64(stat.Uid), 10))
    }
    const name = "sindredesk-lite"
    account, err := user.Lookup(name)
    if err == nil { return account, nil }
    if _, err = exec.LookPath("useradd"); err != nil { return nil, err }
    cmd := exec.Command("useradd", "--system", "--user-group", "--no-create-home", "--shell", "/usr/sbin/nologin", name)
    cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
    if err = cmd.Run(); err != nil { return nil, err }
    return user.Lookup(name)
}

func installService() error {
    if os.Geteuid() != 0 { return errors.New("请使用 sudo 执行 install") }
    if _, err := exec.LookPath("systemctl"); err != nil { return err }
    if _, err := os.Lstat(unitPath); !os.IsNotExist(err) {
        return errors.New("服务已安装或配置路径存在；停止并移除旧 unit 后才能重新注册")
    }
    source, err := os.Executable()
    if err != nil { return err }
    source, err = filepath.EvalSymlinks(source)
    if err != nil { return err }
    info, err := os.Stat(source)
    if err != nil { return err }
    if !info.Mode().IsRegular() { return errors.New("可执行文件不是普通文件") }
    dir, err := stateDir()
    if err != nil { return err }
    executable, err := unitQuote(source)
    if err != nil { return err }
    working, err := unitQuote(filepath.Dir(source))
    if err != nil { return err }
    writable, err := unitQuote(dir)
    if err != nil { return err }
    account, err := serviceAccount(info)
    if err != nil { return err }
    uid, err := strconv.Atoi(account.Uid)
    if err != nil || uid == 0 { return errors.New("拒绝以 root 运行远控服务") }
    gid, err := strconv.Atoi(account.Gid)
    if err != nil { return err }
    access := func(flag, path string) bool {
        return exec.Command("runuser", "-u", account.Username, "--", "test", flag, path).Run() == nil
    }
    if !access("-x", source) {
        return fmt.Errorf("服务账户 %s 无法访问程序；请放在可访问目录，例如 /opt/SindreDeskLite，或普通用户拥有的目录", account.Username)
    }
    if err = os.Mkdir(dir, 0700); err == nil {
        if err = os.Chown(dir, uid, gid); err != nil { return err }
    } else if !os.IsExist(err) { return err }
    state, err := os.Lstat(dir)
    if err != nil { return err }
    owner, ok := state.Sys().(*syscall.Stat_t)
    if !ok || !state.IsDir() || state.Mode().Perm() & 0077 != 0 || int(owner.Uid) != uid || !access("-w", dir) || !access("-x", dir) {
        return fmt.Errorf("已有数据目录必须为非符号链接、0700、由服务账户 %s 持有；不会自动改动已有数据", account.Username)
    }
    unit := fmt.Sprintf(`[Unit]
Description=SindreDeskLite Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%d
Group=%d
WorkingDirectory=%s
ExecStart=%s
ReadWritePaths=%s
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=yes
UMask=0077

[Install]
WantedBy=multi-user.target
`, uid, gid, working, executable, writable)
    f, err := os.OpenFile(unitPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644)
    if err != nil { return err }
    _, writeErr := f.WriteString(unit)
    closeErr := f.Close()
    if writeErr != nil || closeErr != nil {
        os.Remove(unitPath)
        return errors.Join(writeErr, closeErr)
    }
    if err = systemctl("daemon-reload"); err != nil { return err }
    if err = systemctl("enable", "--now", "sindredesk-lite.service"); err != nil { return err }
    fmt.Println("已注册系统服务；请使用 systemctl status sindredesk-lite 检查启动结果。")
    return nil
}
