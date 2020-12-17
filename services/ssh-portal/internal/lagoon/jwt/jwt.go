package jwt

import (
	"time"

	"github.com/dgrijalva/jwt-go"
)

// LagoonClaims is a set of JWT claims used by Lagoon.
type LagoonClaims struct {
	Role string `json:"role"`
	jwt.StandardClaims
}

// OneMinuteAdminToken returns a JWT admin token valid for one minute.
func OneMinuteAdminToken(secret string) (string, error) {
	now := time.Now()
	claims := LagoonClaims{
		Role: "admin",
		StandardClaims: jwt.StandardClaims{
			Audience:  "api.dev",
			ExpiresAt: now.Unix() + 60,
			IssuedAt:  now.Unix(),
			Subject:   "ssh-portal",
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(secret))
}
