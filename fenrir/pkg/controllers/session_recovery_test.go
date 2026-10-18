package controllers

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	v1alpha1 "games-on-whales.github.io/direwolf/pkg/api/v1alpha1"
	direwolffake "games-on-whales.github.io/direwolf/pkg/generated/clientset/versioned/fake"
	"games-on-whales.github.io/direwolf/pkg/generic"
	"games-on-whales.github.io/direwolf/pkg/wolfapi"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/sets"
	"k8s.io/client-go/kubernetes/fake"
	clienttesting "k8s.io/client-go/testing"
	"k8s.io/client-go/tools/cache"
)

func recoveryController(t *testing.T, session *v1alpha1.Session) (*SessionController, *direwolffake.Clientset) {
	t.Helper()
	proxy := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "moonlight-proxy", Namespace: "house"},
		Status: corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{
			Ingress: []corev1.LoadBalancerIngress{{IP: "192.168.1.221"}},
		}},
	}
	deployment := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "jeff-retroarch", Namespace: "house"}}
	sessions := direwolffake.NewSimpleClientset(session)
	sessionInformer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &v1alpha1.Session{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	require.NoError(t, sessionInformer.GetStore().Add(session))
	appInformer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &v1alpha1.App{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	userInformer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &v1alpha1.User{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	deploymentInformer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &appsv1.Deployment{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	require.NoError(t, deploymentInformer.GetStore().Add(deployment))
	return &SessionController{
		K8sClient: fake.NewClientset(proxy, deployment), SessionClient: sessions.DirewolfV1alpha1().Sessions("house"),
		SessionInformer:      generic.NewInformer[*v1alpha1.Session](sessionInformer),
		AppInformer:          generic.NewInformer[*v1alpha1.App](appInformer),
		UserInformer:         generic.NewInformer[*v1alpha1.User](userInformer),
		trackedSessions:      make(map[userGame]sets.Set[string]),
		trackedGames:         make(map[string]userGame),
		deploymentController: generic.NewController(generic.NewInformer[*appsv1.Deployment](deploymentInformer), func(string, string, *appsv1.Deployment) error { return nil }, generic.ControllerOptions{}),
	}, sessions
}

func TestActiveStreamRecoversMissingWolfSessionID(t *testing.T) {
	for _, recoveredID := range []string{"wolf-session-42", ""} {
		t.Run(recoveredID, func(t *testing.T) {
			session := sessionServiceFixture()
			session.Annotations = map[string]string{"direwolf/client-ip": "192.0.2.10"}
			session.Spec.Config.AESKey = "matching-key"
			session.Spec.Config.AESIV = "matching-iv"
			session.Status.ServiceName = session.Name + "-rtp"
			controller, _ := recoveryController(t, session)
			_, err := controller.K8sClient.CoreV1().Services("house").Create(context.Background(), &corev1.Service{
				ObjectMeta: metav1.ObjectMeta{Name: session.Status.ServiceName, Namespace: "house", Annotations: map[string]string{"metallb.io/loadBalancerIPs": "192.168.1.221"}},
				Spec:       corev1.ServiceSpec{ClusterIP: "127.0.0.1"},
				Status:     corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{Ingress: []corev1.LoadBalancerIngress{{IP: "192.168.1.221"}}}},
			}, metav1.CreateOptions{})
			require.NoError(t, err)
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var response any
				switch r.URL.Path {
				case "/api/v1/sessions":
					response = map[string]any{"success": true, "sessions": []wolfapi.Session{
						{ClientID: "unrelated-id", AESKey: "different-key", AESIV: "matching-iv"},
						{ClientID: recoveredID, AESKey: "matching-key", AESIV: "matching-iv"},
					}}
				case "/api/v1/apps":
					response = map[string]any{"success": true, "apps": []wolfapi.App{{ID: "app-42", Title: "retroarch"}}}
				default:
					t.Errorf("recovery must not create a second Wolf session: %s %s", r.Method, r.URL.Path)
					http.Error(w, "unexpected request", http.StatusBadRequest)
					return
				}
				if err := json.NewEncoder(w).Encode(response); err != nil {
					t.Errorf("encode response: %v", err)
				}
			}))
			require.NoError(t, server.Listener.Close())
			listener, err := net.Listen("tcp", "127.0.0.1:8443")
			require.NoError(t, err, "controller uses fixed Wolf API port 8443; fixture must own it")
			server.Listener = listener
			server.StartTLS()
			t.Cleanup(server.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()

			err = controller.reconcileActiveStreams(ctx, session)

			if recoveredID == "" {
				require.ErrorContains(t, err, "missing session ID")
				require.Empty(t, session.Status.StreamURL)
				return
			}
			require.NoError(t, err)
			require.Equal(t, recoveredID, session.Status.WolfSessionID)
			require.Equal(t, "rtsp://192.168.1.221:48010", session.Status.StreamURL)
		})
	}
}

func TestReconcileDoesNotExpireEstablishedStreamWithMissingWolfID(t *testing.T) {
	session := sessionServiceFixture()
	session.CreationTimestamp = metav1.NewTime(time.Now().Add(-time.Hour))
	session.Status.StreamURL = "rtsp://192.168.1.221:48010"
	controller, sessions := recoveryController(t, session)

	err := controller.Reconcile("house", session.Name, session)

	require.ErrorContains(t, err, "waiting for LoadBalancer ingress")
	_, err = controller.SessionClient.Get(context.Background(), session.Name, metav1.GetOptions{})
	require.NoError(t, err)
	for _, action := range sessions.Actions() {
		require.NotEqual(t, "delete", action.GetVerb())
	}
}

func TestReconcileReturnsStatusConflictForRetry(t *testing.T) {
	session := sessionServiceFixture()
	session.CreationTimestamp = metav1.NewTime(time.Now())
	controller, sessions := recoveryController(t, session)
	conflict := apierrors.NewConflict(schema.GroupResource{Group: "direwolf.games-on-whales.github.io", Resource: "sessions"}, session.Name, fmt.Errorf("concurrent status update"))
	sessions.PrependReactor("update", "sessions", func(action clienttesting.Action) (bool, runtime.Object, error) {
		require.Equal(t, "status", action.GetSubresource())
		return true, nil, conflict
	})

	err := controller.Reconcile("house", session.Name, session)

	require.ErrorIs(t, err, conflict)
}
