//go:build linux && amd64

package main

import (
 "context"
 "errors"
 "path/filepath"
 "sync"
 "testing"
)
func TestRegistry(t *testing.T){
 p:=filepath.Join(t.TempDir(),"devices.db")
 r,e:=openRegistry(p);if e!=nil{t.Fatal(e)}
 a,e:=r.register(context.Background(),"a","123456789");if e!=nil{t.Fatal(e)}
 b,e:=r.register(context.Background(),"b","987654321");if e!=nil||a.Code==b.Code||!codePattern.MatchString(a.Code){t.Fatal(a,b,e)}
 if _,e=r.register(context.Background(),"c","123456789");!errors.Is(e,errConflict){t.Fatal(e)}
 if _,e=r.register(context.Background(),"a","222222222");!errors.Is(e,errConflict){t.Fatal(e)}
 r.db.Close();r,e=openRegistry(p);if e!=nil{t.Fatal(e)};defer r.db.Close()
 c,e:=r.register(context.Background(),"a","123456789");if e!=nil||a!=c{t.Fatal(a,c,e)}
}
func TestConcurrent(t *testing.T){
 r,e:=openRegistry(filepath.Join(t.TempDir(),"devices.db"));if e!=nil{t.Fatal(e)};defer r.db.Close()
 var wg sync.WaitGroup;codes:=make(chan string,32)
 for i:=0;i<32;i++{wg.Add(1);go func(i int){defer wg.Done();id:=string(rune('A'+i));d,e:=r.register(context.Background(),id,id+"123456");if e!=nil{t.Error(e);return};codes<-d.Code}(i)}
 wg.Wait();close(codes);seen:=map[string]bool{};for c:=range codes{if seen[c]{t.Fatal("duplicate",c)};seen[c]=true};if len(seen)!=32{t.Fatal(len(seen))}
}
