// Package lagoon implements high-level functions for interacting with the
// Lagoon API.
package lagoon

import (
	"context"
	"encoding/base64"
	"fmt"

	"github.com/smlx/lagoon/services/ssh-portal/internal/schema"
	gossh "golang.org/x/crypto/ssh"
)

// SSH contains methods for getting information about SSH user permissions.
type SSH interface {
	UserBySSHKey(ctx context.Context, key string, user *schema.User) error
	UserCanSSHToEnvironment(ctx context.Context, projectName string, env *schema.Environment) error
}

// UserBySSHKey returns the user associated with the given SSH key.
func UserBySSHKey(ctx context.Context, c SSH, key gossh.PublicKey) (*schema.User, error) {
	user := schema.User{}
	return &user, c.UserBySSHKey(ctx,
		fmt.Sprintf("%s %s",
			key.Type(),
			base64.StdEncoding.EncodeToString(key.Marshal())),
		&user)
}

// UserCanSSHToEnvironment returns true if the current user can SSH to the
// given environment (namespace).
func UserCanSSHToEnvironment(ctx context.Context, c SSH, namespace string) (bool, error) {
	env := schema.Environment{}
	err := c.UserCanSSHToEnvironment(ctx, namespace, &env)
	if env.OpenshiftProjectName == namespace {
		return true, nil
	}
	return false, err
}
