package moonlight

import (
	"bytes"
	"embed"
	"html/template"
	"net/http"
	"sort"

	"k8s.io/klog/v2"
)

//go:embed dashboard.html pin.html updates.html web.css web-*.js
var webFiles embed.FS

var (
	dashboardPage = template.Must(template.ParseFS(webFiles, "dashboard.html"))
	servePINPage  = webAsset("pin.html", "text/html")
)

func (s *RESTServer) registerWeb() {
	s.router.HandleFunc("GET /{$}", s.dashboardHandler)
	s.router.HandleFunc("GET /dashboard", s.dashboardHandler)
	s.router.HandleFunc("/pin/", s.pinHandler)
	s.router.HandleFunc("GET /updates", webAsset("updates.html", "text/html"))
	s.router.HandleFunc("GET /fenrir.css", webAsset("web.css", "text/css"))
	s.router.HandleFunc("GET /fenrir-pairing.js", webAsset("web-pairing.js", "text/javascript"))
	s.router.HandleFunc("GET /fenrir-pin.js", webAsset("web-pin.js", "text/javascript"))
	s.router.HandleFunc("GET /fenrir-updates.js", webAsset("web-updates.js", "text/javascript"))
}

func webAsset(name, contentType string) http.HandlerFunc {
	data, err := webFiles.ReadFile(name)
	if err != nil {
		panic(err)
	}
	return func(w http.ResponseWriter, r *http.Request) {
		writeWeb(w, contentType, data)
	}
}

func writeWeb(w http.ResponseWriter, contentType string, data []byte) {
	w.Header().Set("Content-Type", contentType+"; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(data)
}

func (s *RESTServer) dashboardHandler(w http.ResponseWriter, r *http.Request) {
	secrets := s.manager.GetPendingSecrets()
	sort.Strings(secrets)
	var page bytes.Buffer
	if err := dashboardPage.Execute(&page, secrets); err != nil {
		klog.Errorf("Render pairing dashboard: %v", err)
		http.Error(w, "Could not load the pairing dashboard", http.StatusInternalServerError)
		return
	}
	writeWeb(w, "text/html", page.Bytes())
}
