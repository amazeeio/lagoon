package main

import (
	"fmt"

	"github.com/alecthomas/kong"
	"github.com/gliderlabs/ssh"
	"github.com/smlx/lagoon/services/ssh-portal/internal/exec"
	"github.com/smlx/lagoon/services/ssh-portal/internal/keycloak"
	"go.uber.org/zap"
)

var (
	version   string
	buildTime string
)

// CLI represents the Command Line Interface to ssh-portal
type CLI struct {
	Debug                    bool   `kong:"help='enable debug logging'"`
	Port                     uint   `kong:"default='2222',help='port to listen on'"`
	JWTSecret                string `kong:"required,env='JWTSECRET',help='Lagoon API JWT secret'"`
	KeycloakAuthServerSecret string `kong:"required,env='KEYCLOAK_AUTH_SERVER_CLIENT_SECRET',help='auth-server client secret'"`
	KeycloakAPI              string `kong:"required,env='KEYCLOAK_BASEURL',help='base URL of keycloak API'"`
	LagoonAPI                string `kong:"required,env='GRAPHQL_ENDPOINT',help='base URL of Lagoon API'"`
	HostKeyRSA               string `kong:"required,env='HOSTKEY_RSA',help='RSA ssh host key (PEM)'"`
	HostKeyED25519           string `kong:"required,env='HOSTKEY_ED25519',help='ED25519 ssh host key (PEM)'"`
}

func main() {
	// parse CLI config
	cli := CLI{}
	_ = kong.Parse(&cli)
	// init logger
	var log *zap.Logger
	var err error
	if cli.Debug {
		log, err = zap.NewDevelopment()
	} else {
		log, err = zap.NewProduction()
	}
	if err != nil {
		panic(err)
	}
	defer log.Sync()
	log.Info("startup",
		zap.String("version", version), zap.String("buildTime", buildTime))
	// init keycloak client
	k, err := keycloak.New(cli.KeycloakAPI, cli.KeycloakAuthServerSecret, log)
	if err != nil {
		log.Fatal("couldn't get keycloak client", zap.Error(err))
	}
	// init k8s exec client
	e, err := exec.New()
	if err != nil {
		log.Fatal("couldn't get exec client", zap.Error(err))
	}
	// configure ssh connection handling
	ssh.Handle(sessionHandler(k, e, cli.LagoonAPI, cli.JWTSecret, log, cli.Debug))
	// start SSH server
	log.Fatal("server error", zap.Error(
		ssh.ListenAndServe(
			fmt.Sprintf(":%d", cli.Port),
			nil,
			ssh.PublicKeyAuth(pubKeyAuth(
				log,
				cli.JWTSecret,
				cli.LagoonAPI,
				cli.Debug)),
			ssh.HostKeyPEM([]byte(cli.HostKeyRSA)),
			ssh.HostKeyPEM([]byte(cli.HostKeyED25519)))))
}
