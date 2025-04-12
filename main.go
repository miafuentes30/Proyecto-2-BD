package main

import (
	"log"
	"reservas-concurrentes/config"
	"reservas-concurrentes/database"
	"reservas-concurrentes/services"
	"time"
)

func main() {
	cfg := config.Load()

	err := database.Connect(cfg)
	if err != nil {
		log.Fatalf("Error al conectar a la base de datos: %v", err)
	}
	defer database.Close()

	rs := services.NewReservationService()

	if err := rs.CheckDatabase(); err != nil {
		log.Fatalf("Error al verificar base de datos: %v", err)
	}

	isolationLevels := []string{"READ COMMITTED", "REPEATABLE READ", "SERIALIZABLE"}
	userCounts := []int{5, 10, 20, 30} // niveles de aislamiento

	for _, count := range userCounts {
		for _, isolation := range isolationLevels {
			log.Printf("\n===== INICIANDO PRUEBA CON %d USUARIOS (%s) =====\n", count, isolation)

			// Se debe resetar el estado antes de cada prueba
			if err := rs.ResetBatas(); err != nil {
				log.Printf("Error al resetear batas: %v", err)
				continue
			}

			// Esperar un poco antes de iniciar para asegurar que todo esté limpio
			time.Sleep(2 * time.Second)

			rs.SimulateConcurrentReservations(count, isolation)

			// Dar más tiempo para SERIALIZABLE
			waitTime := 20 * time.Second
			if isolation == "SERIALIZABLE" {
				waitTime = 40 * time.Second
			}
			if count > 20 {
				waitTime = waitTime * 2
			}

			time.Sleep(waitTime)

			// Resetear los "asientos", así iniciamos con 0 reservas de batas.
			if err := rs.ResetBatas(); err != nil {
				log.Printf("Error al resetear batas después de la prueba: %v", err)
			}

			// Esperar después del reset
			time.Sleep(5 * time.Second)
		}
	}
}
