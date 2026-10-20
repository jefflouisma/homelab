package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"games-on-whales.github.io/direwolf/pkg/packages"
	"games-on-whales.github.io/direwolf/pkg/util"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	kube, direwolf, _, _, err := util.GetKubernetesClients()
	if err != nil {
		slog.Error("Kubernetes client", "error", err)
		os.Exit(1)
	}
	namespace := os.Getenv("POD_NAMESPACE")
	sessions := func(ctx context.Context) (int, error) {
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		s, err := direwolf.DirewolfV1alpha1().Sessions(namespace).List(ctx, metav1.ListOptions{})
		if err != nil {
			return 0, err
		}
		p, err := kube.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{LabelSelector: "direwolf/app=emudeck"})
		if err != nil {
			return 0, err
		}
		return len(s.Items) + len(p.Items), nil
	}
	client := &http.Client{Timeout: 5 * time.Minute}
	installer := packages.Installer{Root: packages.DefaultRoot, Client: client, Probe: packages.Probe}
	if err := installer.SeedBundled(ctx, "/opt/es-de"); err != nil {
		slog.Error("preserve bundled frontend", "error", err)
		os.Exit(1)
	}
	manager, err := packages.New(packages.DefaultRoot, packages.Sources{Client: client, GitHub: "https://api.github.com", GitLab: "https://gitlab.com/api/v4"}, installer, sessions)
	if err != nil {
		slog.Error("initialize packages", "error", err)
		os.Exit(1)
	}
	server := &http.Server{Addr: ":8080", Handler: manager.Handler(), ReadHeaderTimeout: 10 * time.Second}
	finished := make(chan struct{})
	go func() { defer close(finished); manager.Run(ctx) }()
	go func() {
		<-ctx.Done()
		shutdown, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if err := server.Shutdown(shutdown); err != nil {
			slog.Error("shutdown package API", "error", err)
		}
	}()
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("package API", "error", err)
		cancel()
	}
	cancel()
	<-finished
}
