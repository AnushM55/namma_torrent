package main

import (
	"fmt"

	"github.com/wlynxg/anet"
)

// findAvailablePort tries to find an available port starting from the given port number
func findAvailablePort(startPort int) (int, error) {
	for port := startPort; port < startPort+100; port++ {
		addr := fmt.Sprintf(":%d", port)
		listener, err := anet.Listen("tcp", addr)
		if err == nil {
			listener.Close()
			return port, nil
		}
	}
	return 0, fmt.Errorf("no available port found")
}
