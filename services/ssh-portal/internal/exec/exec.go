package exec

import (
	"context"
	"fmt"
	"io"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/deprecated/scheme"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
)

// Client is a k8s pod exec client.
type Client struct {
	config    *rest.Config
	clientset *kubernetes.Clientset
}

// New creates a new kubernetes API client.
func New() (*Client, error) {
	// creates the in-cluster config
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, err
	}
	// creates the clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, err
	}
	return &Client{
		config:    config,
		clientset: clientset,
	}, nil
}

// Exec joins the given streams to the command or, if command is empty, to a
// shell running in the given pod.
func (c *Client) Exec(deployment, namespace string, command []string,
	stdio io.ReadWriter, stderr io.Writer, tty bool) error {
	// get the name of the first pod in the deployment
	podName, err := c.podName(deployment, namespace)
	if err != nil {
		return err
	}
	// check the command. if there isn't one, give the user a shell.
	if len(command) == 0 {
		command = []string{"sh"}
	}
	// construct the request
	req := c.clientset.CoreV1().RESTClient().Post().Namespace(namespace).
		Resource("pods").Name(podName).SubResource("exec")
	req.VersionedParams(
		&v1.PodExecOptions{
			Command: command,
			Stdin:   true,
			Stdout:  true,
			Stderr:  true,
			TTY:     tty,
		},
		scheme.ParameterCodec,
	)
	// construct the executor
	exec, err := remotecommand.NewSPDYExecutor(c.config, "POST", req.URL())
	if err != nil {
		return err
	}
	// execute the command
	return exec.Stream(remotecommand.StreamOptions{
		Stdin:  stdio,
		Stdout: stdio,
		Stderr: stderr,
	})
}

func (c *Client) podName(deployment, namespace string) (string, error) {
	d, err := c.clientset.AppsV1().Deployments(namespace).
		Get(context.TODO(), deployment, metav1.GetOptions{})
	if err != nil {
		return "", err
	}
	pods, err := c.clientset.CoreV1().Pods(namespace).
		List(context.TODO(), metav1.ListOptions{
			LabelSelector: labels.FormatLabels(d.Spec.Selector.MatchLabels),
		})

	if len(pods.Items) == 0 {
		return "", fmt.Errorf("no pods for deployment: %s", deployment)
	}

	return pods.Items[0].Name, nil
}
