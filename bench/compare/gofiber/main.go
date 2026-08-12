// Go Fiber — fasthttp underneath. The framework zfast took its tone from in
// v1 (see docs/history.md).
package main

import (
	"log"
	"strconv"
	"strings"

	"github.com/gofiber/fiber/v2"
)

type User struct {
	ID    uint32 `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
	Bio   string `json:"bio"`
}

var bio = strings.Repeat("A systems nerd who writes Zig before breakfast. ", 19)

const maxID = 1000000

func main() {
	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
	})

	app.Get("/users/:id", func(c *fiber.Ctx) error {
		c.Set("Access-Control-Allow-Origin", "*")

		raw := c.Params("id")
		id, err := strconv.ParseUint(raw, 10, 32)
		if err != nil || id == 0 || id > maxID {
			return c.Status(fiber.StatusNotFound).SendString("no user " + raw)
		}

		// c.JSON serialises per request, like zfast.
		return c.JSON(User{uint32(id), "Routed Tester", "tester@example.dev", bio})
	})

	app.Get("/health", func(c *fiber.Ctx) error {
		return c.SendString("alive\n")
	})

	log.Fatal(app.Listen("127.0.0.1:8802"))
}
