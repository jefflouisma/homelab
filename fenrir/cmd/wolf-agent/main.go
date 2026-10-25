package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sync/atomic"
	"time"

	"games-on-whales.github.io/direwolf/pkg/controllers"
	"games-on-whales.github.io/direwolf/pkg/util"
	"games-on-whales.github.io/direwolf/pkg/wolfapi"
	"k8s.io/klog/v2"
)

func main() {
	appContext, appCancel := context.WithCancel(context.Background())
	defer appCancel()

	serverCertPath := flag.String("tls-cert", "server.crt", "Path to server cert")
	serverKeyPath := flag.String("tls-key", "server.key", "Path to server key")
	serverPort := flag.Int("port", 443, "Port to listen on")
	wolfSocketPath := flag.String("socket", "/var/run/wolf.sock", "Path to wolf.sock")
	klog.InitFlags(nil)
	flag.Parse()

	klog.Info("Starting wolf-agent")
	klog.Info("TLS Cert:", *serverCertPath)
	klog.Info("TLS Key:", *serverKeyPath)
	klog.Info("Port:", *serverPort)
	klog.Info("Wolf Socket:", *wolfSocketPath)
	client := UnixHTTPClient(*wolfSocketPath)

	// Generate self-signed certificate and key
	cert, err := util.LoadCertificates(*serverCertPath, *serverKeyPath)
	if err != nil {
		klog.Fatal("Failed to load certificates:", err)
	}

	agentController := controllers.NewAgent(wolfapi.NewClient(
		fmt.Sprintf("https://localhost:%d", *serverPort),
		&http.Client{
			Transport: &http.Transport{
				TLSClientConfig:       &tls.Config{InsecureSkipVerify: true},
				ResponseHeaderTimeout: 10 * time.Second,
			},
		},
	))
	var socketReady atomic.Bool
	go func() {
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()
		for {
			if info, err := os.Stat(*wolfSocketPath); err == nil && info.Mode()&os.ModeSocket != 0 {
				dialer := net.Dialer{Timeout: time.Second}
				conn, err := dialer.DialContext(appContext, "unix", *wolfSocketPath)
				if err == nil {
					if err := conn.Close(); err != nil {
						klog.ErrorS(err, "Closing socket readiness connection")
					}
					socketReady.Store(true)
					if err := agentController.Run(appContext); err != nil && appContext.Err() == nil {
						klog.ErrorS(err, "Agent stopped; retrying event subscription")
					}
					socketReady.Store(false)
				} else {
					klog.Warningf("Waiting for wolf.sock to accept connections: %v", err)
				}
			} else if err == nil {
				klog.Fatal("wolf.sock is not a socket", info.Mode())
			}
			select {
			case <-appContext.Done():
				return
			case <-ticker.C:
			}
		}
	}()

	// Spin up HTTPS server with self-signed certificate to service the wolf.sock
	mux := http.NewServeMux()
	mux.HandleFunc("/input-devices", agentController.ServeInputDevices)
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if agentController.Ready() {
			w.WriteHeader(http.StatusOK)
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	})
	mux.HandleFunc("/livez", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/api/v1/", func(w http.ResponseWriter, r *http.Request) {
		klog.Info("Received request:", r.Method, r.URL.Path)
		if !socketReady.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}

		//!TODO: Use kubernetes metric.Filter or something to implement RBAC
		// authorization against the bearer token
		// Proxy the request to the wolf.sock
		url, err := url.JoinPath("http://", "wolf.sock", r.URL.Path)
		if err != nil {
			klog.ErrorS(err, "Failed to join URL")
			http.Error(w, fmt.Sprintf("Failed to join URL: %v", err), http.StatusInternalServerError)
			return
		}
		request, err := http.NewRequestWithContext(r.Context(), r.Method, url, r.Body)
		if err != nil {
			klog.ErrorS(err, "Failed to create proxy request")
			http.Error(w, fmt.Sprintf("Failed to create proxy request: %v", err), http.StatusInternalServerError)
			return
		}
		request.Proto = r.Proto
		request.ProtoMajor = r.ProtoMajor
		request.ProtoMinor = r.ProtoMinor
		request.TransferEncoding = r.TransferEncoding
		request.ContentLength = r.ContentLength
		request.Header = r.Header.Clone()

		// Send the request to the wolf.sock
		klog.Info("Sending request to wolf.sock:", request.Method, request.URL.Path)
		response, err := client.Do(request)
		if err != nil {
			klog.ErrorS(err, "Failed to send request to wolf.sock")
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer response.Body.Close()

		// Write the response back to the client
		for key, values := range response.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}
		w.WriteHeader(response.StatusCode)
		flusher, ok := w.(http.Flusher)
		if !ok {
			klog.Error("Flushing not supported! Aborting writing response")
			return
		}

		flusher.Flush()

		// Stream response body manually. io.Copy doesn't eagerly flush
		// which breaks SSE stream.
		buf := make([]byte, 4096)
		for {
			n, err := response.Body.Read(buf)
			if n > 0 {
				_, writeErr := w.Write(buf[:n])
				if writeErr != nil {
					klog.Info("Client connection closed")
					return
				}
				flusher.Flush() // Ensure immediate delivery
			}
			if err != nil {
				if err == io.EOF {
					break
				}
				klog.ErrorS(err, "Error reading from backend")
				return
			}
		}
		klog.InfoS("Request completed", "statusCode", response.StatusCode)
	})

	// Start HTTPS server
	server := &http.Server{
		Addr:    fmt.Sprintf(":%d", *serverPort),
		Handler: mux,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
		},
	}

	klog.Infof("Listening on port %d\n", *serverPort)
	err = server.ListenAndServeTLS("", "")
	if err != nil {
		klog.Fatal("Failed to start server:", err)
	}
}

func UnixHTTPClient(sockAddr string) http.Client {
	return http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", sockAddr)
			},
		},
	}
}
