package schema

import "github.com/google/uuid"

// User provides for unmarshalling the users.
type User struct {
	ID    uuid.UUID `json:"id"`
	Email string    `json:"email"`
}
