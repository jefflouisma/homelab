package controllers

import (
	"context"
	"errors"
	"testing"

	"games-on-whales.github.io/direwolf/pkg/generic"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	clienttesting "k8s.io/client-go/testing"
	"k8s.io/client-go/tools/cache"
)

func TestExistingDeploymentCannotAdoptDifferentResolution(t *testing.T) {
	for _, tc := range []struct {
		name, width string
		applyError  bool
	}{{"different_width", "1920", false}, {"api_error", "1280", true}, {"compatible", "1280", false}} {
		t.Run(tc.name, func(t *testing.T) {
			session := sessionServiceFixture()
			session.Spec.Config.VideoWidth = 1280
			session.Spec.Config.VideoHeight = 720
			session.Spec.Config.VideoRefreshRate = 60
			deployment := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "jeff-retroarch", Namespace: "house"}, Spec: appsv1.DeploymentSpec{Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "retroarch", Env: []corev1.EnvVar{{Name: "GAMESCOPE_WIDTH", Value: tc.width}, {Name: "GAMESCOPE_HEIGHT", Value: "720"}, {Name: "GAMESCOPE_REFRESH", Value: "60"}}}}}}}}
			informer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &appsv1.Deployment{}, 0, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
			require.NoError(t, informer.GetStore().Add(deployment))
			client := fake.NewClientset(deployment)
			applyFailure := errors.New("deployment apply failed")
			client.PrependReactor("patch", "deployments", func(clienttesting.Action) (bool, runtime.Object, error) {
				if tc.applyError {
					return true, nil, applyFailure
				}
				return true, deployment, nil
			})
			controller := &SessionController{K8sClient: client, deploymentController: generic.NewController(generic.NewInformer[*appsv1.Deployment](informer), func(string, string, *appsv1.Deployment) error { return nil }, generic.ControllerOptions{})}
			err := controller.reconcilePod(context.Background(), session)
			switch tc.name {
			case "different_width":
				require.Error(t, err)
				require.Empty(t, client.Actions())
			case "api_error":
				require.ErrorIs(t, err, applyFailure)
			case "compatible":
				require.NoError(t, err)
				require.Len(t, client.Actions(), 1)
			}
		})
	}
}
