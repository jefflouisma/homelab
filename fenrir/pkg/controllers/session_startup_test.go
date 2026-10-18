package controllers

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/utils/ptr"
)

func startupObjects() (*appsv1.Deployment, *appsv1.ReplicaSet, *corev1.Pod) {
	labels := map[string]string{"direwolf/user": "jeff", "direwolf/app": "retroarch"}
	deployment := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "jeff-retroarch", Namespace: "house", UID: "deployment-current", Generation: 2}, Spec: appsv1.DeploymentSpec{Replicas: ptr.To(int32(1)), Selector: &metav1.LabelSelector{MatchLabels: labels}, Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: labels}, Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "wolf-agent", Image: "agent-current"}, {Name: "emudeck", Image: "app-current"}}}}}, Status: appsv1.DeploymentStatus{ObservedGeneration: 2, Replicas: 1}}
	rs := &appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Name: "worker-rs", Namespace: "house", UID: "rs-current", OwnerReferences: []metav1.OwnerReference{{Kind: "Deployment", Name: deployment.Name, UID: deployment.UID, Controller: ptr.To(true)}}}, Spec: appsv1.ReplicaSetSpec{Template: *deployment.Spec.Template.DeepCopy()}}
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: "worker-pod", Namespace: "house", Labels: labels, OwnerReferences: []metav1.OwnerReference{{Kind: "ReplicaSet", Name: rs.Name, UID: rs.UID, Controller: ptr.To(true)}}}, Spec: *deployment.Spec.Template.Spec.DeepCopy(), Status: corev1.PodStatus{Phase: corev1.PodRunning, PodIP: "127.0.0.1", ContainerStatuses: []corev1.ContainerStatus{{Name: "wolf-agent", Ready: true, State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}}}, {Name: "emudeck", Ready: false, State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff"}}}}}}
	return deployment, rs, pod
}

func TestStreamStartupWaitsOnlyForOwnedDesiredWolfAgent(t *testing.T) {
	for _, scenario := range []string{"app_waiting", "agent_waiting", "no_pods", "no_ip", "terminating", "foreign_owner", "stale_rs_uid", "stale_template", "stale_generation", "scaled_zero"} {
		t.Run(scenario, func(t *testing.T) {
			deployment, rs, pod := startupObjects()
			rs.Spec.Template.Labels[appsv1.DefaultDeploymentUniqueLabelKey] = "current-hash"
			if scenario != "app_waiting" {
				deployment.Status.ReadyReplicas = 1
			}
			switch scenario {
			case "agent_waiting":
				pod.Status.ContainerStatuses[0].Ready = false
			case "no_ip":
				pod.Status.PodIP = ""
			case "terminating":
				now := metav1.Now()
				pod.DeletionTimestamp = &now
			case "foreign_owner":
				rs.OwnerReferences[0].UID = "another-deployment"
			case "stale_rs_uid":
				pod.OwnerReferences[0].UID = "deleted-replicaset"
			case "stale_template":
				rs.Spec.Template.Spec.Containers[0].Image = "old-agent"
			case "stale_generation":
				deployment.Status.ObservedGeneration = 1
			case "scaled_zero":
				deployment.Spec.Replicas = ptr.To(int32(0))
			}
			client := fake.NewClientset(deployment, rs)
			if scenario != "no_pods" {
				_, err := client.CoreV1().Pods("house").Create(context.Background(), pod, metav1.CreateOptions{})
				require.NoError(t, err)
			}
			controller := &SessionController{K8sClient: client}
			session := sessionServiceFixture()
			session.Status.ServiceName = "stream"
			session.Annotations = map[string]string{"direwolf/client-ip": "192.0.2.10"}
			_, err := client.CoreV1().Services("house").Create(context.Background(), &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: "stream", Namespace: "house", Annotations: map[string]string{"metallb.io/loadBalancerIPs": "192.168.1.221"}}, Spec: corev1.ServiceSpec{ClusterIP: "192.0.2.20"}, Status: corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{Ingress: []corev1.LoadBalancerIngress{{IP: "192.168.1.221"}}}}}, metav1.CreateOptions{})
			require.NoError(t, err)
			if scenario == "app_waiting" {
				server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					http.Error(w, "fixture reached", http.StatusServiceUnavailable)
				}))
				require.NoError(t, server.Listener.Close())
				listener, err := net.Listen("tcp", "127.0.0.1:8443")
				require.NoError(t, err)
				server.Listener = listener
				server.StartTLS()
				t.Cleanup(server.Close)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			err = controller.reconcileActiveStreams(ctx, session)
			require.Error(t, err)
			if scenario == "app_waiting" {
				require.ErrorContains(t, err, "failed to list sessions")
				require.ErrorContains(t, err, "503")
			} else {
				require.ErrorContains(t, err, "not ready")
			}
		})
	}
}
