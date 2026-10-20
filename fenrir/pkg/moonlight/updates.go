package moonlight

import (
	_ "embed"
	"net/http"
	"net/http/httputil"
	"net/url"
)

//go:embed updates.html
var updatesHTML string

func (s *RESTServer) registerUpdates() {
	proxy := httputil.NewSingleHostReverseProxy(&url.URL{Scheme: "http", Host: "fenrir-packages:8080"})
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		http.Error(w, "The update service is unavailable. Try again shortly.", http.StatusBadGateway)
	}
	s.router.Handle("/api/updates", proxy)
	s.router.Handle("/api/updates/", proxy)
	s.router.HandleFunc("GET /updates", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Write([]byte(updatesHTML))
	})
}
