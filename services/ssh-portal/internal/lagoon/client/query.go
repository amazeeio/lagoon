package client

import (
	"context"

	"github.com/smlx/lagoon/services/ssh-portal/internal/schema"
)

// UserBySSHKey queries the Lagoon API for a user by their public SSH key, and
// unmarshals the response into user.
func (c *Client) UserBySSHKey(
	ctx context.Context, key string, user *schema.User) error {

	req, err := c.newRequest("_lgraphql/userBySshKey.graphql",
		map[string]interface{}{
			"sshKey": key,
		})
	if err != nil {
		return err
	}

	return c.client.Run(ctx, req, &struct {
		Response *schema.User `json:"userBySshKey"`
	}{
		Response: user,
	})
}

// UserCanSSHToEnvironment queries the Lagoon API to check if the user can SSH
// to the environment.
func (c *Client) UserCanSSHToEnvironment(
	ctx context.Context, namespace string, env *schema.Environment) error {

	req, err := c.newRequest("_lgraphql/userCanSshToEnvironment.graphql",
		map[string]interface{}{
			"openshiftProjectName": namespace,
		})
	if err != nil {
		return err
	}

	return c.client.Run(ctx, req, &struct {
		Response *schema.Environment `json:"userCanSshToEnvironment"`
	}{
		Response: env,
	})
}
