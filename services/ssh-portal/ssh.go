package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"

	"github.com/gliderlabs/ssh"
	"github.com/google/uuid"
	"github.com/smlx/lagoon/services/ssh-portal/internal/exec"
	"github.com/smlx/lagoon/services/ssh-portal/internal/keycloak"
	"github.com/smlx/lagoon/services/ssh-portal/internal/lagoon"
	lclient "github.com/smlx/lagoon/services/ssh-portal/internal/lagoon/client"
	"github.com/smlx/lagoon/services/ssh-portal/internal/lagoon/jwt"
	"github.com/smlx/lagoon/services/ssh-portal/internal/schema"
	"go.uber.org/zap"
)

// context key types
type key int

var userKey key

// pubKeyAuth performs a check against the lagoon API for the public key
func pubKeyAuth(log *zap.Logger, jwtSecret, lagoonAPI string, debug bool) ssh.PublicKeyHandler {
	return func(ctx ssh.Context, key ssh.PublicKey) bool {
		// generate a JWT token
		token, err := jwt.OneMinuteAdminToken(jwtSecret)
		if err != nil {
			log.Error("couldn't get JWT token", zap.Error(err))
			return false
		}
		// get the lagoon client with the admin token
		l := lclient.New(lagoonAPI, token, "ssh-portal "+version, debug)
		// get the user ID from lagoon
		keyLogField := zap.String("publicKey", fmt.Sprintf("%s %s",
			key.Type(),
			base64.StdEncoding.EncodeToString(key.Marshal())))
		user, err := lagoon.UserBySSHKey(context.TODO(), l, key)
		if err != nil {
			log.Debug("unknown SSH key", keyLogField, zap.Error(err))
			return false
		}
		log.Info("accepted public key", keyLogField, zap.String("userID", user.ID.String()))
		ctx.SetValue(userKey, user)
		return true
	}
}

// sessionHandler contains the main ssh session logic
func sessionHandler(k *keycloak.Client, c *exec.Client,
	lagoonAPI, jwtSecret string, log *zap.Logger, debug bool) ssh.Handler {
	return func(s ssh.Session) {
		// generate session ID
		sid := uuid.New()
		log.Info("start session", zap.String("sessionID", sid.String()))
		defer log.Info("end session", zap.String("sessionID", sid.String()))
		// extract the user object that was added to the context during
		// authentication
		user, ok := s.Context().Value(userKey).(*schema.User)
		if !ok {
			log.Error("unknown context value for user",
				zap.String("sessionID", sid.String()))
			io.WriteString(s, "internal error\n")
			return
		}
		log.Info("identified user",
			zap.String("userID", user.ID.String()),
			zap.String("userEmail", user.Email),
			zap.String("sessionID", sid.String()))
		// get a user token from keycloak
		ctoken, err := k.UserToken(&user.ID)
		if err != nil {
			log.Warn("couldn't get user token", zap.Error(err),
				zap.String("sessionID", sid.String()))
			io.WriteString(s, "internal error\n")
			return
		}
		// check the user and command. if it is "lagoon" and "token" respectively,
		// return the user token and exit. This is used to get a graphql token via
		// SSH.
		cmd := s.Command()
		if s.User() == "lagoon" && len(cmd) == 1 && cmd[0] == "token" {
			log.Info("issuing user token", zap.String("sessionID", sid.String()))
			io.WriteString(s, ctoken)
			io.WriteString(s, "\n")
			return
		}
		// get the lagoon client using the user token
		cl := lclient.New(lagoonAPI, ctoken, "ssh-portal "+version, true)
		// Now, authenticated as the user, check for SSH permissions on the
		// namespace. Here, s.User() is the ssh username - for Lagoon this is the
		// namespace name
		canSSH, err := lagoon.UserCanSSHToEnvironment(context.TODO(), cl, s.User())
		if err != nil {
			log.Warn("couldn't get user SSH permissions", zap.Error(err),
				zap.String("sessionID", sid.String()))
			io.WriteString(s, "internal error\n")
			return
		}
		if !canSSH {
			log.Info("permission denied", zap.Error(err),
				zap.String("sessionID", sid.String()))
			io.WriteString(s, "permission denied\n")
			return
		}
		// check if a pty is required
		_, _, pty := s.Pty()
		// start the command
		err = c.Exec("cli", s.User(), s.Command(), s, s.Stderr(), pty)
		if err != nil {
			log.Warn("couldn't execute command", zap.Error(err),
				zap.String("sessionID", sid.String()))
			io.WriteString(s, "couldn't execute command\n")
		}
	}
}
