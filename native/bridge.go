package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
	"unsafe"

	"tailscale.com/tsnet"
)

var runtimeMu sync.Mutex
var node *tsnet.Server
var controlAddress string
var proxyServer *http.Server
var proxyTransport *http.Transport
var proxyConnections sync.Map

func result(v any, err error) *C.char {
	if err != nil { v = map[string]string{"error": err.Error()} }
	b, e := json.Marshal(v)
	if e != nil { b = []byte(`{"error":"Could not encode bridge response"}`) }
	return C.CString(string(b))
}

//export PocketFree
func PocketFree(value *C.char) { C.free(unsafe.Pointer(value)) }

//export PocketStart
func PocketStart(stateDir, controlURL *C.char) *C.char {
	runtimeMu.Lock()
	defer runtimeMu.Unlock()
	control := C.GoString(controlURL)
	if control != "" {
		u, err := url.Parse(control)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
			return result(nil, errors.New("Control server must be an HTTPS URL"))
		}
	}
	if node != nil {
		if controlAddress != control { return result(nil, errors.New("Stop Tailscale before changing control server")) }
		return result(map[string]bool{"started": true}, nil)
	}
	if err := os.MkdirAll(C.GoString(stateDir), 0700); err != nil { return result(nil, err) }
	// No Tailscale support log uploads. The control plane is still required for enrollment/discovery.
	os.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")
	s := &tsnet.Server{Dir: C.GoString(stateDir), Hostname: "comfyuipocket", ControlURL: control,
		Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {}}
	if err := s.Start(); err != nil { s.Close(); return result(nil, err) }
	node = s
	controlAddress = control
	return result(map[string]bool{"started": true}, nil)
}

//export PocketStatus
func PocketStatus() *C.char {
	runtimeMu.Lock()
	defer runtimeMu.Unlock()
	if node == nil { return result(map[string]string{"state": "Stopped"}, nil) }
	client, err := node.LocalClient()
	if err != nil { return result(nil, err) }
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil { return result(nil, err) }
	if status.BackendState == "NeedsLogin" && status.AuthURL == "" {
		if err := client.StartLoginInteractive(ctx); err != nil { return result(nil, err) }
	}
	ips := []string{}
	for _, ip := range status.TailscaleIPs { ips = append(ips, ip.String()) }
	peers := []map[string]any{}
	for _, p := range status.Peer {
		peers = append(peers, map[string]any{"name": p.HostName, "online": p.Online, "directEndpoint": p.CurAddr})
	}
	return result(map[string]any{"state": status.BackendState, "authURL": status.AuthURL, "ips": ips,
		"peers": peers, "dataPolicy": "direct-only"}, nil)
}

func validateTarget(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil ||
		u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, errors.New("Target must be an HTTP(S) IP address and port")
	}
	address, err := netip.ParseAddrPort(u.Host)
	if err != nil || address.Port() == 0 || !address.Addr().IsValid() || address.Addr().IsUnspecified() || address.Addr().IsMulticast() {
		return nil, errors.New("Target must have a valid IP address and port")
	}
	return u, nil
}

type trackedConn struct { net.Conn }
func (c *trackedConn) Close() error { proxyConnections.Delete(c); return c.Conn.Close() }

func closeProxy() {
	if proxyServer != nil { proxyServer.Close(); proxyServer = nil }
	if proxyTransport != nil { proxyTransport.CloseIdleConnections(); proxyTransport = nil }
	proxyConnections.Range(func(key, _ any) bool { key.(*trackedConn).Close(); return true })
}

//export PocketForward
func PocketForward(targetURL *C.char) *C.char {
	runtimeMu.Lock()
	defer runtimeMu.Unlock()
	if node == nil { return result(nil, errors.New("Start Tailscale first")) }
	target, err := validateTarget(C.GoString(targetURL))
	if err != nil { return result(nil, err) }
	closeProxy()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil { return result(nil, err) }
	secret := make([]byte, 32)
	if _, err = rand.Read(secret); err != nil { listener.Close(); return result(nil, err) }
	token := hex.EncodeToString(secret)
	activeNode := node
	transport := &http.Transport{
		Proxy: nil, ForceAttemptHTTP2: false, ResponseHeaderTimeout: 30*time.Second,
		TLSHandshakeTimeout: 15*time.Second, IdleConnTimeout: 30*time.Second,
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
			defer cancel()
			conn, err := activeNode.Dial(ctx, "tcp", target.Host)
			if err != nil { return nil, err }
			tracked := &trackedConn{conn}; proxyConnections.Store(tracked, true)
			return tracked, nil
		},
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			r.Out.Host = target.Host
			r.Out.Header.Del("X-Pocket-Bridge")
			r.Out.Header.Del("Origin")
		},
		Transport: transport,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "Direct Tailscale connection failed. Check login, peer IP, ACL and UDP reachability. Relaying application data is disabled.", http.StatusBadGateway)
		},
	}
	address := listener.Addr().String()
	server := &http.Server{ReadHeaderTimeout: 10*time.Second, IdleTimeout: 60*time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Host != address || subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Pocket-Bridge")), []byte(token)) != 1 {
				http.Error(w, "Forbidden", http.StatusForbidden); return
			}
			if r.Method == http.MethodConnect || strings.Contains(r.URL.Path, "\x00") {
				http.Error(w, "Invalid request", http.StatusBadRequest); return
			}
			proxy.ServeHTTP(w, r)
		})}
	proxyServer, proxyTransport = server, transport
	go server.Serve(listener)
	return result(map[string]string{"url": "http://"+address, "token": token}, nil)
}

//export PocketStop
func PocketStop() {
	runtimeMu.Lock()
	defer runtimeMu.Unlock()
	closeProxy()
	if node != nil { node.Close(); node = nil }
}

func main() {}
