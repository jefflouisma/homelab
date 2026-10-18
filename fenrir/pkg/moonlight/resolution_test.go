package moonlight

import (
	"context"
	"encoding/xml"
	"errors"
	"net/http/httptest"
	"testing"

	api "games-on-whales.github.io/direwolf/pkg/api/v1alpha1"
	fake "games-on-whales.github.io/direwolf/pkg/generated/clientset/versioned/fake"
	"games-on-whales.github.io/direwolf/pkg/generic"
	"github.com/stretchr/testify/require"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	clienttesting "k8s.io/client-go/testing"
	"k8s.io/client-go/tools/cache"
)

type resolutionPodLister struct {
	generic.NamespacedLister[*v1.Pod]
	list func(labels.Selector) ([]*v1.Pod, error)
}

func (l resolutionPodLister) List(selector labels.Selector) ([]*v1.Pod, error) {
	return l.list(selector)
}

func resolutionRESTFixture(t *testing.T) (*RESTServer, *fake.Clientset, context.Context) {
	t.Helper()
	indexer := cache.NewIndexer(cache.MetaNamespaceKeyFunc, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	session := &api.Session{ObjectMeta: metav1.ObjectMeta{Name: "active", Namespace: "house", Labels: map[string]string{"direwolf/user": "jeff"}}, Spec: api.SessionSpec{Config: api.SessionInfo{VideoWidth: 1920, VideoHeight: 1080, VideoRefreshRate: 60}}, Status: api.SessionStatus{StreamURL: "rtsp://192.168.1.221:48010"}}
	require.NoError(t, indexer.Add(session))
	apps := cache.NewIndexer(cache.MetaNamespaceKeyFunc, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	require.NoError(t, apps.Add(&api.App{ObjectMeta: metav1.ObjectMeta{Name: "emudeck", Namespace: "house"}, Spec: api.AppSpec{ID: 1}}))
	client := fake.NewSimpleClientset(session)
	client.PrependReactor("create", "sessions", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, nil, errors.New("unexpected session creation")
	})
	ctx := context.WithValue(context.Background(), userContextKey{}, &api.User{ObjectMeta: metav1.ObjectMeta{Name: "jeff", Namespace: "house"}})
	ctx = context.WithValue(ctx, pairingContextKey{}, &api.Pairing{ObjectMeta: metav1.ObjectMeta{Name: "pair", Namespace: "house"}})
	server := &RESTServer{SessionLister: generic.NewLister[*api.Session](indexer).Namespaced("house"), SessionClient: client.DirewolfV1alpha1().Sessions("house"), AppLister: generic.NewLister[*api.App](apps).Namespaced("house")}
	server.PodLister = resolutionPodLister{list: func(labels.Selector) ([]*v1.Pod, error) { return nil, errors.New("cleanup fixture unavailable") }}
	return server, client, ctx
}

func TestLaunchRejectsNonpositiveModeBeforeSessionMutation(t *testing.T) {
	for _, mode := range []string{"-1x720x60", "1280x0x60", "1280x720x-60", "1280x720x0"} {
		t.Run(mode, func(t *testing.T) {
			s, client, ctx := resolutionRESTFixture(t)
			response := httptest.NewRecorder()
			s.launchHandler(response, httptest.NewRequest("GET", "/launch?appid=1&rikey=test&rikeyid=1&mode="+mode, nil).WithContext(ctx))
			require.Equal(t, 400, response.Code)
			require.Empty(t, client.Actions())
		})
	}
}

func TestResumePreservesSessionAndChecksRequestedMode(t *testing.T) {
	for _, tc := range []struct {
		mode string
		code int
	}{{"1280x720x60", 409}, {"1920x1080x30", 409}, {"-1x720x60", 400}, {"1920x1080x60", 200}, {"", 200}} {
		t.Run(tc.mode, func(t *testing.T) {
			s, client, ctx := resolutionRESTFixture(t)
			response := httptest.NewRecorder()
			s.resumeHandler(response, httptest.NewRequest("GET", "/resume?mode="+tc.mode, nil).WithContext(ctx))
			require.Equal(t, tc.code, response.Code)
			var result ResumeResponse
			require.NoError(t, xml.Unmarshal(response.Body.Bytes(), &result))
			require.Equal(t, tc.code, result.StatusCode)
			if tc.code == 200 {
				require.Equal(t, 1, result.Resume)
				require.Equal(t, "rtsp://192.168.1.221:48010", result.RTSPSessionURL)
			}
			require.Empty(t, client.Actions())
		})
	}
}

func TestLaunchDoesNotCreateSessionBeforePodCleanup(t *testing.T) {
	s, client, ctx := resolutionRESTFixture(t)
	response := httptest.NewRecorder()
	s.launchHandler(response, httptest.NewRequest("GET", "/launch?appid=1&rikey=test&rikeyid=1&mode=1280x720x60", nil).WithContext(ctx))
	require.Equal(t, 500, response.Code)
	for _, action := range client.Actions() {
		require.NotEqual(t, "create", action.GetVerb())
	}
}

func TestCancelWaitsForPodsAfterSessionAlreadyDeleted(t *testing.T) {
	s, _, ctx := resolutionRESTFixture(t)
	empty := cache.NewIndexer(cache.MetaNamespaceKeyFunc, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	s.SessionLister = generic.NewLister[*api.Session](empty).Namespaced("house")
	calls := 0
	s.PodLister = resolutionPodLister{list: func(selector labels.Selector) ([]*v1.Pod, error) {
		calls++
		require.True(t, selector.Matches(labels.Set{"direwolf/user": "jeff"}))
		if calls == 1 {
			return []*v1.Pod{{ObjectMeta: metav1.ObjectMeta{Name: "terminating"}}}, nil
		}
		return nil, nil
	}}
	response := httptest.NewRecorder()
	s.cancelHandler(response, httptest.NewRequest("GET", "/cancel", nil).WithContext(ctx))
	require.Equal(t, 200, response.Code)
	require.GreaterOrEqual(t, calls, 2)
}

func TestCleanupStopsWhenRequestIsCancelled(t *testing.T) {
	s, _, ctx := resolutionRESTFixture(t)
	empty := cache.NewIndexer(cache.MetaNamespaceKeyFunc, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	s.SessionLister = generic.NewLister[*api.Session](empty).Namespaced("house")
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	s.PodLister = resolutionPodLister{list: func(labels.Selector) ([]*v1.Pod, error) {
		cancel()
		return []*v1.Pod{{ObjectMeta: metav1.ObjectMeta{Name: "terminating"}}}, nil
	}}
	err := s.stopSessionsForUser(ctx, ctx.Value(userContextKey{}).(*api.User))
	require.ErrorIs(t, err, context.Canceled)
}
