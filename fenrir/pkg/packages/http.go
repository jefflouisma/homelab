package packages

import (
	"encoding/json"
	"net/http"
)

func (m *Manager) Handler() http.Handler {
	router := http.NewServeMux()
	router.HandleFunc("GET /api/updates", func(w http.ResponseWriter, r *http.Request) {
		data, err := m.Snapshot()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(data)
	})
	router.HandleFunc("POST /api/updates/{component}/{action}", func(w http.ResponseWriter, r *http.Request) {
		id, err := ParseComponent(r.PathValue("component"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		switch r.PathValue("action") {
		case "check":
			err = m.Check(id)
		case "apply":
			err = m.Queue(id, "")
		case "cancel":
			err = m.Cancel(id)
		case "rollback":
			var body struct {
				Version string `json:"version"`
			}
			decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
			decoder.DisallowUnknownFields()
			if err = decoder.Decode(&body); err == nil {
				if body.Version == "" {
					http.Error(w, "select a retained version", 400)
					return
				}
				err = m.Queue(id, body.Version)
			}
		default:
			http.NotFound(w, r)
			return
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		w.Write([]byte(`{"accepted":true}`))
	})
	return router
}
