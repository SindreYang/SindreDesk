//go:build linux && amd64

package main

import (
    "context"
    "crypto/ecdsa"
    "crypto/elliptic"
    "crypto/rand"
    "crypto/sha256"
    "crypto/tls"
    "crypto/x509"
    "crypto/x509/pkix"
    "database/sql"
    "encoding/hex"
    "encoding/json"
    "encoding/pem"
    "errors"
    "fmt"
    "io"
    "log"
    "math/big"
    "net"
    "net/http"
    "os"
    "path/filepath"
    "regexp"
    "strings"
    "sync"
    "time"

    _ "github.com/mattn/go-sqlite3"
)

const defaultIP = "43.138.240.23"
var nativeID = regexp.MustCompile(`^[A-Za-z0-9_-]{6,64}$`)
var codePattern = regexp.MustCompile(`^[0-9]{4}$`)

type registry struct {
    db *sql.DB
    mu sync.Mutex
    limits map[string]bucket
}
type bucket struct { until time.Time; count int }
type device struct { Code string `json:"code"`; RustdeskID string `json:"rustdesk_id"` }

func openRegistry(path string) (*registry, error) {
    db, err := sql.Open("sqlite3", path+"?_busy_timeout=5000&_journal_mode=WAL&_synchronous=FULL")
    if err != nil { return nil, err }
    db.SetMaxOpenConns(1)
    _, err = db.Exec(`CREATE TABLE IF NOT EXISTS devices (
        identity TEXT PRIMARY KEY, code TEXT NOT NULL UNIQUE CHECK(length(code)=4 AND code NOT GLOB '*[^0-9]*'),
        rustdesk_id TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1))
    )`)
    if err != nil { db.Close(); return nil, err }
    return &registry{db:db, limits:map[string]bucket{}}, nil
}

// 令牌由客户端随机生成并持久化；服务端只保存摘要。四位码不是认证密码。
func identity(req *http.Request) (string, bool) {
    token := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
    raw, err := hex.DecodeString(token)
    if err != nil || len(raw) != 32 || !strings.HasPrefix(req.Header.Get("Authorization"), "Bearer ") { return "",false }
    sum := sha256.Sum256(raw)
    return hex.EncodeToString(sum[:]),true
}

func (r *registry) allowed(k string, limit int) bool {
    r.mu.Lock(); defer r.mu.Unlock()
    now := time.Now()
    for key,v := range r.limits { if !now.Before(v.until) { delete(r.limits,key) } }
    if len(r.limits) >= 20000 { if _,ok:=r.limits[k]; !ok { return false } }
    b := r.limits[k]
    if b.count == 0 { b.until = now.Add(time.Minute) }
    if b.count >= limit { return false }
    b.count++; r.limits[k]=b; return true
}

var errFull = errors.New("device capacity exhausted")
var errConflict = errors.New("device identity conflict")

func (r *registry) register(ctx context.Context, id, peer string) (device,error) {
    tx,err:=r.db.BeginTx(ctx,nil); if err!=nil {return device{},err}; defer tx.Rollback()
    var d device; var enabled int
    err=tx.QueryRowContext(ctx,"SELECT code,rustdesk_id,enabled FROM devices WHERE identity=?",id).Scan(&d.Code,&d.RustdeskID,&enabled)
    now:=time.Now().Unix()
    if err==nil {
        if d.RustdeskID!=peer || enabled!=1 {return device{},errConflict}
        if _,err=tx.ExecContext(ctx,"UPDATE devices SET last_seen=? WHERE identity=?",now,id);err!=nil{return device{},err}
        return d,tx.Commit()
    }
    if !errors.Is(err,sql.ErrNoRows){return device{},err}
    var exists int
    if err=tx.QueryRowContext(ctx,"SELECT count(*) FROM devices WHERE rustdesk_id=?",peer).Scan(&exists);err!=nil{return device{},err}
    if exists!=0{return device{},errConflict}
    rows,err:=tx.QueryContext(ctx,"SELECT code FROM devices");if err!=nil{return device{},err}
    used:=make(map[string]bool)
    for rows.Next(){var code string;if err=rows.Scan(&code);err!=nil{rows.Close();return device{},err};used[code]=true}
    err=rows.Err();rows.Close();if err!=nil{return device{},err}
    if len(used)>=10000{return device{},errFull}
    start,err:=rand.Int(rand.Reader,big.NewInt(10000));if err!=nil{return device{},err}
    for i:=0;i<10000;i++{code:=fmt.Sprintf("%04d",(int(start.Int64())+i)%10000);if !used[code]{d=device{Code:code,RustdeskID:peer};break}}
    _,err=tx.ExecContext(ctx,"INSERT INTO devices(identity,code,rustdesk_id,created_at,last_seen) VALUES(?,?,?,?,?)",id,d.Code,peer,now,now)
    if err!=nil{return device{},err};return d,tx.Commit()
}

func reply(w http.ResponseWriter, status int, v any) {
    w.Header().Set("Content-Type","application/json")
    w.Header().Set("Cache-Control","no-store")
    w.WriteHeader(status); _=json.NewEncoder(w).Encode(v)
}
func failure(w http.ResponseWriter, status int) {reply(w,status,map[string]string{"error":http.StatusText(status)})}
func decode(w http.ResponseWriter, req *http.Request, v any) bool {
    req.Body=http.MaxBytesReader(w,req.Body,2048)
    d:=json.NewDecoder(req.Body);d.DisallowUnknownFields()
    if d.Decode(v)!=nil || d.Decode(new(any))!=io.EOF {failure(w,400);return false};return true
}

func (r *registry) handler() http.Handler {
    mux:=http.NewServeMux()
    mux.HandleFunc("GET /health",func(w http.ResponseWriter,req *http.Request){
        if r.db.PingContext(req.Context())!=nil || !portsReady(){failure(w,503);return}
        reply(w,200,map[string]string{"status":"online","service":"sindredesk-lite","version":"1"})
    })
    mux.HandleFunc("POST /v1/register",func(w http.ResponseWriter,req *http.Request){
        id,ok:=identity(req);if !ok{failure(w,401);return}
        ip,_,_:=net.SplitHostPort(req.RemoteAddr)
        if !r.allowed("register-ip:"+ip,30)||!r.allowed("register-id:"+id,12){failure(w,429);return}
        var body struct{ RustdeskID string `json:"rustdesk_id"` }
        if !decode(w,req,&body){return};if !nativeID.MatchString(body.RustdeskID){failure(w,400);return}
        d,err:=r.register(req.Context(),id,body.RustdeskID)
        switch {case errors.Is(err,errFull):failure(w,507);case errors.Is(err,errConflict):failure(w,409);case err!=nil:failure(w,500);default:reply(w,200,d)}
    })
    mux.HandleFunc("POST /v1/lookup",func(w http.ResponseWriter,req *http.Request){
        id,ok:=identity(req);if !ok{failure(w,401);return}
        ip,_,_:=net.SplitHostPort(req.RemoteAddr)
        if !r.allowed("lookup-ip:"+ip,20)||!r.allowed("lookup-id:"+id,5){failure(w,429);return}
        var body struct{ Code string `json:"code"` };if !decode(w,req,&body){return}
        if !codePattern.MatchString(body.Code){failure(w,400);return}
        var enabled int
        err:=r.db.QueryRowContext(req.Context(),"SELECT enabled FROM devices WHERE identity=?",id).Scan(&enabled)
        if errors.Is(err,sql.ErrNoRows)||(err==nil&&enabled!=1){failure(w,403);return};if err!=nil{failure(w,500);return}
        var d device
        err=r.db.QueryRowContext(req.Context(),"SELECT code,rustdesk_id FROM devices WHERE code=? AND enabled=1 AND identity<>?",body.Code,id).Scan(&d.Code,&d.RustdeskID)
        if errors.Is(err,sql.ErrNoRows){failure(w,404);return};if err!=nil{failure(w,500);return}
        // 只返回路由 ID；真实会话必须由被控设备通过 RustDesk 原生确认。
        reply(w,200,d)
    })
    return mux
}

func certificate(dir string) (string,string,error) {
    certPath,keyPath:=filepath.Join(dir,"api.crt"),filepath.Join(dir,"api.key")
    _,ce:=os.Stat(certPath);_,ke:=os.Stat(keyPath)
    if ce==nil && ke==nil {return certPath,keyPath,nil}
    if !os.IsNotExist(ce)||!os.IsNotExist(ke){return "","",errors.New("TLS 文件不完整，拒绝自动替换")}
    priv,err:=ecdsa.GenerateKey(elliptic.P256(),rand.Reader);if err!=nil{return "","",err}
    serial,err:=rand.Int(rand.Reader,new(big.Int).Lsh(big.NewInt(1),128));if err!=nil{return "","",err}
    addr:=os.Getenv("SINDREDESK_PUBLIC_IP");if addr==""{addr=defaultIP}
    ip:=net.ParseIP(addr);if ip==nil{return "","",errors.New("SINDREDESK_PUBLIC_IP 无效")}
    now:=time.Now()
    tpl:=&x509.Certificate{SerialNumber:serial,Subject:pkix.Name{CommonName:"SindreDeskLite"},NotBefore:now.Add(-time.Hour),NotAfter:now.AddDate(5,0,0),IPAddresses:[]net.IP{ip},KeyUsage:x509.KeyUsageDigitalSignature,ExtKeyUsage:[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},BasicConstraintsValid:true}
    der,err:=x509.CreateCertificate(rand.Reader,tpl,tpl,&priv.PublicKey,priv);if err!=nil{return "","",err}
    pk,err:=x509.MarshalPKCS8PrivateKey(priv);if err!=nil{return "","",err}
    if err=os.WriteFile(keyPath,pem.EncodeToMemory(&pem.Block{Type:"PRIVATE KEY",Bytes:pk}),0600);err!=nil{return "","",err}
    if err=os.WriteFile(certPath,pem.EncodeToMemory(&pem.Block{Type:"CERTIFICATE",Bytes:der}),0600);err!=nil{os.Remove(keyPath);return "","",err}
    return certPath,keyPath,nil
}

type runningAPI struct {server *http.Server; registry *registry; done chan error}
func (a *runningAPI) close(){ctx,cancel:=context.WithTimeout(context.Background(),5*time.Second);defer cancel();_ = a.server.Shutdown(ctx);_ = a.server.Close();_ = a.registry.db.Close()}
func startAPI(dir string)(*runningAPI,error){
    cert,key,err:=certificate(dir);if err!=nil{return nil,err}
    pair,err:=tls.LoadX509KeyPair(cert,key);if err!=nil{return nil,err}
    r,err:=openRegistry(filepath.Join(dir,"devices.db"));if err!=nil{return nil,err}
    listener,err:=net.Listen("tcp",":22120");if err!=nil{r.db.Close();return nil,err}
    srv:=&http.Server{Handler:r.handler(),ReadHeaderTimeout:3*time.Second,ReadTimeout:5*time.Second,WriteTimeout:5*time.Second,IdleTimeout:15*time.Second,MaxHeaderBytes:8192,TLSConfig:&tls.Config{MinVersion:tls.VersionTLS12,Certificates:[]tls.Certificate{pair}}}
    a:=&runningAPI{server:srv,registry:r,done:make(chan error,1)}
    go func(){a.done<-srv.Serve(tls.NewListener(listener,srv.TLSConfig))}()
    log.Print("设备码 HTTPS 服务: 22120")
    return a,nil
}
