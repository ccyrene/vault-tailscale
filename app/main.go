package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	secretsFile := os.Getenv("SECRETS_FILE")
	if secretsFile == "" {
		secretsFile = "/vault/secrets/credentials"
	}
	interval := 15 * time.Second

	go func() {
		for {
			data, err := os.ReadFile(secretsFile)
			if err != nil {
				log.Printf("waiting for Vault Agent to render %s: %v", secretsFile, err)
			} else {
				fmt.Println("==== vault credentials ====")
				fmt.Print(string(data))
				if len(data) > 0 && data[len(data)-1] != '\n' {
					fmt.Println()
				}
				fmt.Println("===========================")
			}
			time.Sleep(interval)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/creds", func(w http.ResponseWriter, r *http.Request) {
		data, err := os.ReadFile(secretsFile)
		if err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write(data)
	})

	addr := ":8080"
	log.Printf("vault-consumer listening on %s, polling %s every %s", addr, secretsFile, interval)
	log.Fatal(http.ListenAndServe(addr, mux))
}
