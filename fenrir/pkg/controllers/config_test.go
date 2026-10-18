package controllers_test

import (
	_ "embed"
	"testing"

	"games-on-whales.github.io/direwolf/pkg/api/v1alpha1"
	"games-on-whales.github.io/direwolf/pkg/controllers"
	"github.com/pelletier/go-toml/v2"
	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
)

//go:embed firefox.yaml
var firefox string

func TestConfig(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := v1alpha1.Install(scheme); err != nil {
		t.Fatal(err)
	}

	codecs := serializer.NewCodecFactory(scheme)
	res, _, err := codecs.UniversalDeserializer().Decode([]byte(firefox), nil, nil)
	if err != nil {
		t.Fatal(err)
	}

	t.Log("Successfully decoded the config")

	tomls, err := controllers.GenerateWolfConfig(res.(*v1alpha1.App), []*v1alpha1.Pairing{
		{Spec: v1alpha1.PairingSpec{ClientCertPEM: "test-client-cert"}},
	})
	if err != nil {
		t.Fatal(err)
	}

	var config struct {
		Version  int `toml:"config_version"`
		Profiles []struct {
			Apps []struct {
				Title  string `toml:"title"`
				Runner struct {
					Type string `toml:"type"`
				} `toml:"runner"`
			} `toml:"apps"`
		} `toml:"profiles"`
		Clients []struct {
			Cert  string `toml:"client_cert"`
			State string `toml:"app_state_folder"`
		} `toml:"paired_clients"`
	}
	require.NoError(t, toml.Unmarshal([]byte(tomls), &config))
	require.Equal(t, 6, config.Version)
	require.Len(t, config.Profiles, 1)
	require.Len(t, config.Profiles[0].Apps, 1)
	require.Equal(t, "Firefox", config.Profiles[0].Apps[0].Title)
	require.Equal(t, "process", config.Profiles[0].Apps[0].Runner.Type)
	require.Len(t, config.Clients, 1)
	require.Equal(t, "test-client-cert", config.Clients[0].Cert)
	require.Equal(t, "state", config.Clients[0].State)
}
