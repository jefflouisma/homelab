package controllers

import (
	"context"
	"testing"
	"time"

	v1alpha1 "games-on-whales.github.io/direwolf/pkg/api/v1alpha1"
	direwolffake "games-on-whales.github.io/direwolf/pkg/generated/clientset/versioned/fake"
	"games-on-whales.github.io/direwolf/pkg/generic"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/sets"
	"k8s.io/client-go/kubernetes/fake"
	clienttesting "k8s.io/client-go/testing"
	"k8s.io/client-go/tools/cache"
)

func sessionServiceFixture() *v1alpha1.Session {
	return &v1alpha1.Session{
		ObjectMeta: metav1.ObjectMeta{Name: "jeff-retroarch-new", Namespace: "house", UID: "new-session"},
		Spec: v1alpha1.SessionSpec{
			UserReference: v1alpha1.UserReference{Name: "jeff"},
			GameReference: v1alpha1.GameReference{Name: "retroarch"},
		},
		Status: v1alpha1.SessionStatus{
			Conditions: []metav1.Condition{{Type: "PortsAllocated", Status: metav1.ConditionTrue}},
			Ports:      v1alpha1.SessionPorts{RTSP: 48010, Control: 47999, VideoRTP: 48100, AudioRTP: 48200},
		},
	}
}

func TestSessionServiceRequestsProxyVIPWhileOldPortsAreTerminating(t *testing.T) {
	// Given
	proxy := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "moonlight-proxy", Namespace: "house"},
		Status: corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{
			Ingress: []corev1.LoadBalancerIngress{{IP: "192.168.1.221"}},
		}},
	}
	old := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name: "jeff-emudeck-old-rtp", Namespace: "house",
			Labels:            map[string]string{"app": "direwolf-worker"},
			Finalizers:        []string{"service.kubernetes.io/load-balancer-cleanup"},
			DeletionTimestamp: &metav1.Time{},
		},
		Spec:   corev1.ServiceSpec{Ports: []corev1.ServicePort{{Port: 48010, Protocol: corev1.ProtocolTCP}}},
		Status: proxy.Status,
	}
	deployment := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "jeff-retroarch", Namespace: "house"}}
	client := fake.NewClientset(proxy, old, deployment)
	client.PrependReactor("delete", "services", func(action clienttesting.Action) (bool, runtime.Object, error) {
		return true, nil, nil
	})
	controller := &SessionController{K8sClient: client, SessionControllerOptions: SessionControllerOptions{LBSharingKey: "house"}}
	session := sessionServiceFixture()
	// When
	err := controller.reconcileService(context.Background(), session)
	// Then
	require.NoError(t, err)
	service, err := client.CoreV1().Services("house").Get(context.Background(), session.Status.ServiceName, metav1.GetOptions{})
	require.NoError(t, err)
	require.Equal(t, "192.168.1.221", service.Annotations["metallb.io/loadBalancerIPs"])
	require.Equal(t, "house", service.Annotations["metallb.universe.tf/allow-shared-ip"])
	require.Equal(t, "house", service.Annotations["lbipam.cilium.io/sharing-key"])
	require.Empty(t, service.Status.LoadBalancer.Ingress)
	_, err = client.CoreV1().Services("house").Get(context.Background(), old.Name, metav1.GetOptions{})
	require.NoError(t, err)
	err = controller.reconcileActiveStreams(context.Background(), session)
	require.Error(t, err)
	require.True(t, isTransientStreamError(err))
	require.Empty(t, session.Status.StreamURL)
}

func TestSessionServiceWaitsWhenProxyHasNoVIP(t *testing.T) {
	// Given
	client := fake.NewClientset(&corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: "moonlight-proxy", Namespace: "house"}})
	controller := &SessionController{K8sClient: client}
	session := sessionServiceFixture()
	// When
	err := controller.reconcileService(context.Background(), session)
	// Then
	require.Error(t, err)
	require.True(t, isTransientStreamError(err))
	for _, action := range client.Actions() {
		require.Equal(t, "get", action.GetVerb(), "missing proxy VIP must not mutate Services")
	}
}

func TestActiveStreamWaitsForRequestedVIP(t *testing.T) {
	for _, actualIP := range []string{"", "192.168.1.224"} {
		t.Run(actualIP, func(t *testing.T) {
			// Given
			session := sessionServiceFixture()
			session.Status.ServiceName = "jeff-retroarch-new-rtp"
			service := &corev1.Service{
				ObjectMeta: metav1.ObjectMeta{Name: session.Status.ServiceName, Namespace: "house", Annotations: map[string]string{"metallb.io/loadBalancerIPs": "192.168.1.221"}},
				Status:     corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{Ingress: []corev1.LoadBalancerIngress{{IP: actualIP}}}},
			}
			deployment := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "jeff-retroarch", Namespace: "house"}}
			client := fake.NewClientset(service, deployment)
			controller := &SessionController{K8sClient: client}
			// When
			err := controller.reconcileActiveStreams(context.Background(), session)
			// Then
			require.ErrorContains(t, err, "waiting for LoadBalancer ingress")
			require.True(t, isTransientStreamError(err))
			require.Empty(t, session.Status.StreamURL)
		})
	}
}

func TestReconcileReturnsServiceAndStreamFailuresForRetry(t *testing.T) {
	for _, proxyIP := range []string{"", "192.168.1.221"} {
		t.Run(proxyIP, func(t *testing.T) {
			// Given
			session := sessionServiceFixture()
			session.CreationTimestamp = metav1.NewTime(time.Now())
			proxy := &corev1.Service{
				ObjectMeta: metav1.ObjectMeta{Name: "moonlight-proxy", Namespace: "house"},
				Status:     corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{Ingress: []corev1.LoadBalancerIngress{{IP: proxyIP}}}},
			}
			deployment := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "jeff-retroarch", Namespace: "house"}}
			client := fake.NewClientset(proxy, deployment)
			sessions := direwolffake.NewSimpleClientset(session).DirewolfV1alpha1().Sessions("house")
			sessionInformer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &v1alpha1.Session{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
			require.NoError(t, sessionInformer.GetStore().Add(session))
			appInformer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &v1alpha1.App{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
			userInformer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &v1alpha1.User{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
			deploymentInformer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &appsv1.Deployment{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
			require.NoError(t, deploymentInformer.GetStore().Add(deployment))
			controller := &SessionController{
				K8sClient: client, SessionClient: sessions,
				SessionInformer:      generic.NewInformer[*v1alpha1.Session](sessionInformer),
				AppInformer:          generic.NewInformer[*v1alpha1.App](appInformer),
				UserInformer:         generic.NewInformer[*v1alpha1.User](userInformer),
				trackedSessions:      make(map[userGame]sets.Set[string]),
				trackedGames:         make(map[string]userGame),
				deploymentController: generic.NewController(generic.NewInformer[*appsv1.Deployment](deploymentInformer), func(string, string, *appsv1.Deployment) error { return nil }, generic.ControllerOptions{}),
			}
			// When
			err := controller.Reconcile("house", session.Name, session)
			// Then
			require.ErrorContains(t, err, "waiting for LoadBalancer ingress")
			stored, err := sessions.Get(context.Background(), session.Name, metav1.GetOptions{})
			require.NoError(t, err)
			require.Empty(t, stored.Status.StreamURL)
			require.True(t, meta.IsStatusConditionPresentAndEqual(stored.Status.Conditions, "StreamStarted", metav1.ConditionFalse))
		})
	}
}
