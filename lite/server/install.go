//go:build linux && amd64

package main

import (
 "errors"
 "fmt"
 "io"
 "os"
 "os/exec"
 "path/filepath"
)
const unitPath="/etc/systemd/system/sindredesk-lite.service"
const binPath="/usr/local/bin/SindreDeskLiteServer"
const unitText=`[Unit]
Description=SindreDeskLite Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sindredesk-lite
Group=sindredesk-lite
StateDirectory=sindredesk-lite
StateDirectoryMode=0700
Environment=SINDREDESK_DATA_DIR=/var/lib/sindredesk-lite
ExecStart=/usr/local/bin/SindreDeskLiteServer
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
UMask=0077

[Install]
WantedBy=multi-user.target
`
func systemctl(args ...string)error{cmd:=exec.Command("systemctl",args...);cmd.Stdout=os.Stdout;cmd.Stderr=os.Stderr;return cmd.Run()}
func installService()error{
 if os.Geteuid()!=0{return errors.New("请使用 sudo 执行 install")}
 if _,err:=exec.LookPath("systemctl");err!=nil{return err}
 for _,p:=range []string{unitPath,binPath}{if _,err:=os.Lstat(p);!os.IsNotExist(err){return fmt.Errorf("已安装或路径存在，拒绝覆盖: %s",p)}}
 source,err:=os.Executable();if err!=nil{return err}
 in,err:=os.Open(source);if err!=nil{return err};defer in.Close()
 if err=os.MkdirAll(filepath.Dir(binPath),0755);err!=nil{return err}
 if _,err=exec.LookPath("useradd");err!=nil{return err}
 if err=exec.Command("id","-u","sindredesk-lite").Run();err!=nil{
   cmd:=exec.Command("useradd","--system","--user-group","--no-create-home","--shell","/usr/sbin/nologin","sindredesk-lite")
   cmd.Stdout=os.Stdout;cmd.Stderr=os.Stderr
   if err=cmd.Run();err!=nil{return err}
 }
 out,err:=os.OpenFile(binPath,os.O_CREATE|os.O_EXCL|os.O_WRONLY,0755);if err!=nil{return err}
 _,copyErr:=io.Copy(out,in);closeErr:=out.Close()
 if copyErr!=nil||closeErr!=nil{os.Remove(binPath);return errors.Join(copyErr,closeErr)}
 f,err:=os.OpenFile(unitPath,os.O_CREATE|os.O_EXCL|os.O_WRONLY,0644);if err!=nil{os.Remove(binPath);return err}
 _,writeErr:=f.WriteString(unitText);closeErr=f.Close();if writeErr!=nil||closeErr!=nil{os.Remove(unitPath);os.Remove(binPath);return errors.Join(writeErr,closeErr)}
 if err=systemctl("daemon-reload");err!=nil{return err}
 if err=systemctl("enable","--now","sindredesk-lite.service");err!=nil{return err}
 fmt.Println("已注册系统服务；请使用 systemctl status sindredesk-lite 检查启动结果。")
 return nil
}
