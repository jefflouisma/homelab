package moonlight

import (
	"net/http"
	"net/http/httputil"
	"net/url"
)

func (s *RESTServer) registerUpdates() {
	proxy := httputil.NewSingleHostReverseProxy(&url.URL{Scheme: "http", Host: "fenrir-packages:8080"})
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		http.Error(w, "The update service is unavailable. Try again shortly.", http.StatusBadGateway)
	}
	s.router.Handle("/api/updates", proxy)
	s.router.Handle("/api/updates/", proxy)
}
