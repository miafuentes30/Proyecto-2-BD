package services

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"reservas-concurrentes/database"
	"reservas-concurrentes/models"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type ReservationService struct {
	db       *pgxpool.Pool
	mu       sync.Mutex
	waitList map[int]bool
}

func NewReservationService() *ReservationService {
	return &ReservationService{
		db:       database.GetPool(),
		waitList: make(map[int]bool),
	}
}

func (s *ReservationService) CheckDatabase() error {
	ctx := context.Background()
	var result int
	err := s.db.QueryRow(ctx, "SELECT 1").Scan(&result)
	if err != nil {
		return fmt.Errorf("error al verificar conexión a BD: %w", err)
	}

	var count int
	err = s.db.QueryRow(ctx, "SELECT COUNT(*) FROM batas").Scan(&count)
	if err != nil {
		return fmt.Errorf("error al contar batas: %w", err)
	}
	log.Printf("Total de batas en BD: %d", count)

	return nil
}

// Función para obtener los IDs de estudiantes validos de la BD
func (s *ReservationService) GetValidStudentIDs() ([]int, error) {
	ctx := context.Background()
	rows, err := s.db.Query(ctx, "SELECT id_estudiante FROM estudiantes")
	if err != nil {
		return nil, fmt.Errorf("error al obtener estudiantes: %w", err)
	}
	defer rows.Close()

	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("error al escanear ID de estudiante: %w", err)
		}
		ids = append(ids, id)
	}

	if err = rows.Err(); err != nil {
		return nil, fmt.Errorf("error después de leer filas: %w", err)
	}

	if len(ids) == 0 {
		return nil, fmt.Errorf("no se encontraron estudiantes en la base de datos")
	}

	return ids, nil
}

// Funcion para reservas de batas (asientos)
func (s *ReservationService) TryReserveBata(userID int, bataID int, isolationLevel string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var tx pgx.Tx
	var err error

	// Se intenta más niveles de serializable
	maxRetries := 10
	if isolationLevel == "SERIALIZABLE" {
		maxRetries = 20
	}

	for attempt := 0; attempt < maxRetries; attempt++ {
		if attempt > 0 {
			baseDelay := time.Duration(attempt*attempt) * 20 * time.Millisecond
			jitter := time.Duration(rand.Intn(100)) * time.Millisecond
			time.Sleep(baseDelay + jitter)
		}

		txOpts := pgx.TxOptions{}
		switch isolationLevel {
		case "READ COMMITTED":
			txOpts.IsoLevel = pgx.ReadCommitted
		case "REPEATABLE READ":
			txOpts.IsoLevel = pgx.RepeatableRead
		case "SERIALIZABLE":
			txOpts.IsoLevel = pgx.Serializable
		}

		tx, err = s.db.BeginTx(ctx, txOpts)
		if err != nil {
			continue
		}

		// Verificar si el usuario ya tiene una reserva
		var tieneReserva bool
		err = tx.QueryRow(ctx, `
            SELECT EXISTS(
                SELECT 1 FROM reservas 
                WHERE id_estudiante = $1 
                AND id_estado IN (1, 2, 3) 
                AND fecha_fin > NOW()
            )`, userID).Scan(&tieneReserva)

		if err != nil {
			tx.Rollback(ctx)
			continue
		}

		if tieneReserva {
			tx.Rollback(ctx)
			return false, nil
		}

		// Verificar que la bata sigue disponible con "FOR UPDATE SKIP LOCKED" para evitar bloqueos
		var bataDisponible bool
		err = tx.QueryRow(ctx, `
            SELECT disponible FROM batas 
            WHERE id_bata = $1 AND disponible = true
            FOR UPDATE SKIP LOCKED`, bataID).Scan(&bataDisponible)

		if err != nil {
			tx.Rollback(ctx)
			if err == pgx.ErrNoRows {
				return false, nil // Bata no existe o no esta disponible
			}
			continue
		}

		// Actualizar el estado de la bata
		_, err = tx.Exec(ctx, `
            UPDATE batas 
            SET disponible = false 
            WHERE id_bata = $1`, bataID)

		if err != nil {
			tx.Rollback(ctx)
			continue
		}

		// Crear la reserva
		_, err = tx.Exec(ctx, `
            INSERT INTO reservas 
            (id_estudiante, id_bata, id_laboratorio, id_estado, fecha_solicitud, fecha_inicio, fecha_fin)
            VALUES ($1, $2, 1, 2, NOW(), NOW() + interval '30 minutes', NOW() + interval '2 hours 30 minutes')`,
			userID, bataID)

		if err != nil {
			tx.Rollback(ctx)
			continue
		}

		err = tx.Commit(ctx)
		if err == nil {
			return true, nil
		}

		// Identificar específicamente los errores de serialización ya que no ejecutaba
		if pgErr, ok := err.(*pgconn.PgError); ok {
			// 40001 es el código para serialization_failure
			// 40P01 es el código para deadlock_detected
			if pgErr.Code == "40001" || pgErr.Code == "40P01" {
				// Log para depuración
				if attempt > 10 {
					log.Printf("Reintento %d por error de serialización para usuario %d y bata %d",
						attempt, userID, bataID)
				}
				continue
			}
		}

		return false, fmt.Errorf("error al confirmar transacción: %w", err)
	}

	return false, fmt.Errorf("máximo de reintentos alcanzado para usuario %d y bata %d", userID, bataID)
}

func (s *ReservationService) GetAvailableBatas() ([]models.Bata, error) {
	ctx := context.Background()
	rows, err := s.db.Query(ctx, `
        SELECT b.id_bata, b.codigo, b.id_talla, b.estado, b.disponible, b.fecha_adquisicion
        FROM batas b
        WHERE b.disponible = true
        ORDER BY b.id_bata`)

	if err != nil {
		return nil, fmt.Errorf("error al obtener batas disponibles: %w", err)
	}
	defer rows.Close()

	var batas []models.Bata
	for rows.Next() {
		var b models.Bata
		var fechaAdq time.Time
		err := rows.Scan(&b.ID, &b.Codigo, &b.IDTalla, &b.Estado, &b.Disponible, &fechaAdq)
		if err != nil {
			return nil, fmt.Errorf("error al escanear bata: %w", err)
		}
		b.FechaAdquisicion = fechaAdq
		batas = append(batas, b)
	}

	if err = rows.Err(); err != nil {
		return nil, fmt.Errorf("error después de leer filas: %w", err)
	}

	return batas, nil
}

// Metodo para asignar una bata a un usuario en la lista de espera
func (s *ReservationService) AssignBataToWaitingUser(userID int, isolationLevel string) (bool, int, error) {
	availableBatas, err := s.GetAvailableBatas()
	if err != nil {
		return false, 0, fmt.Errorf("error al obtener batas disponibles: %w", err)
	}

	if len(availableBatas) == 0 {
		return false, 0, nil
	}

	// Intentar reservar cualquiera de las batas disponibles
	for _, bata := range availableBatas {
		success, err := s.TryReserveBata(userID, bata.ID, isolationLevel)
		if err != nil {
			continue
		}
		if success {
			return true, bata.ID, nil
		}
	}

	return false, 0, nil
}

// DESDE ACA SE PUEDE PARTIR PARA QUE CADA USUARIO HAGA COMMIT

// Función para realizar la concurrencia de las reswrvaciones
func (s *ReservationService) SimulateConcurrentReservations(userCount int, isolationLevel string) {
	validStudentIDs, err := s.GetValidStudentIDs()
	if err != nil {
		log.Printf("Error al obtener IDs de estudiantes válidos: %v\n", err)
		return
	}

	if userCount > len(validStudentIDs) {
		userCount = len(validStudentIDs)
	}

	rand.Shuffle(len(validStudentIDs), func(i, j int) {
		validStudentIDs[i], validStudentIDs[j] = validStudentIDs[j], validStudentIDs[i]
	})
	users := validStudentIDs[:userCount]

	startTime := time.Now()
	log.Printf("\n=== Iniciando simulación con %d usuarios y nivel %s ===\n", userCount, isolationLevel)

	initialBatas, err := s.GetAvailableBatas()
	if err != nil {
		log.Printf("Error al obtener batas disponibles: %v\n", err)
		return
	}

	if len(initialBatas) == 0 {
		log.Printf("No hay batas disponibles para la simulación\n")
		return
	}

	log.Printf("Batas disponibles al inicio: %d\n", len(initialBatas))

	results := make(chan string, userCount)

	var wg sync.WaitGroup
	wg.Add(userCount)

	assignments := make(map[int]int)
	var mu sync.Mutex

	maxConcurrent := 10
	if isolationLevel == "SERIALIZABLE" {
		maxConcurrent = 5
		if userCount > 20 {
			maxConcurrent = 3
		}
	} else if userCount > 20 {
		maxConcurrent = 15
	}

	sem := make(chan struct{}, maxConcurrent)

	bataDist := make(map[int][]int)
	bataPorUsuario := len(initialBatas) / userCount
	if bataPorUsuario < 1 {
		bataPorUsuario = 1
	}

	batasArray := make([]int, 0, len(initialBatas))
	for _, bata := range initialBatas {
		batasArray = append(batasArray, bata.ID)
	}
	rand.Shuffle(len(batasArray), func(i, j int) {
		batasArray[i], batasArray[j] = batasArray[j], batasArray[i]
	})

	for i, userID := range users {
		start := (i * bataPorUsuario) % len(batasArray)
		batasUsuario := make([]int, 0, bataPorUsuario)
		for j := 0; j < bataPorUsuario && j+start < len(batasArray); j++ {
			batasUsuario = append(batasUsuario, batasArray[j+start])
		}
		bataDist[userID] = batasUsuario
	}

	for _, userID := range users {
		go func(id int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			preferredBatas := bataDist[id]
			for _, bID := range preferredBatas {
				time.Sleep(time.Duration(rand.Intn(300)) * time.Millisecond)

				success, err := s.TryReserveBata(id, bID, isolationLevel)
				if err != nil {
					continue
				}
				if success {
					mu.Lock()
					assignments[id] = bID
					mu.Unlock()
					results <- fmt.Sprintf("Usuario %d: reservó exitosamente bata %d (preferida)", id, bID)
					return
				}
			}

			maxRetries := 30
			if isolationLevel == "SERIALIZABLE" {
				maxRetries = 50
			}

			for attempt := 0; attempt < maxRetries; attempt++ {
				if attempt > 0 {
					baseDelay := time.Duration(attempt*attempt) * 10 * time.Millisecond
					jitter := time.Duration(rand.Intn(200)) * time.Millisecond
					time.Sleep(baseDelay + jitter)
				}

				availableBatas, err := s.GetAvailableBatas()
				if err != nil || len(availableBatas) == 0 {
					continue
				}

				rand.Shuffle(len(availableBatas), func(i, j int) {
					availableBatas[i], availableBatas[j] = availableBatas[j], availableBatas[i]
				})

				for _, bata := range availableBatas {
					success, err := s.TryReserveBata(id, bata.ID, isolationLevel)
					if err != nil {
						continue
					}
					if success {
						mu.Lock()
						assignments[id] = bata.ID
						mu.Unlock()
						results <- fmt.Sprintf("Usuario %d: reservó exitosamente bata %d (intento %d)", id, bata.ID, attempt+1)
						return
					}
				}

				mu.Lock()
				completionRate := float64(len(assignments)) / float64(userCount)
				mu.Unlock()

				if completionRate > 0.8 && attempt > 10 {
					log.Printf("Usuario %d: Intensificando intentos (tasa actual: %.2f%%)", id, completionRate*100)

					for bataTry := 0; bataTry < 20; bataTry++ {
						allBatas, _ := s.GetAvailableBatas()
						if len(allBatas) == 0 {
							time.Sleep(50 * time.Millisecond)
							continue
						}

						for _, bata := range allBatas {
							success, err := s.TryReserveBata(id, bata.ID, isolationLevel)
							if err != nil {
								continue
							}
							if success {
								mu.Lock()
								assignments[id] = bata.ID
								mu.Unlock()
								results <- fmt.Sprintf("Usuario %d: finalmente reservó bata %d (intento agresivo)", id, bata.ID)
								return
							}
						}
						time.Sleep(50 * time.Millisecond)
					}
				}
			}

			results <- fmt.Sprintf("Usuario %d: no pudo reservar bata después de múltiples intentos", id)
		}(userID)
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	for msg := range results {
		log.Println(msg)
	}

	finalBatas, _ := s.GetAvailableBatas()
	reserved := len(initialBatas) - len(finalBatas)

	log.Printf("\n=== Resultados para %d usuarios (%s) ===\n", userCount, isolationLevel)
	log.Printf("Tiempo total: %v\n", time.Since(startTime))
	log.Printf("Reservas exitosas: %d\n", len(assignments))
	log.Printf("Batas disponibles al final: %d\n", len(finalBatas))
	log.Printf("Porcentaje de éxito: %.2f%%\n", float64(len(assignments))/float64(userCount)*100)
	log.Printf("Total de batas reservadas: %d\n", reserved)

	if len(assignments) == userCount {
		log.Printf("ÉXITO: Todos los usuarios recibieron una bata\n")
	} else {
		log.Printf("ADVERTENCIA: %d usuarios no recibieron bata\n", userCount-len(assignments))
	}
}

func (s *ReservationService) ResetBatas() error {
	ctx := context.Background()

	// Iniciar transacción
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return fmt.Errorf("error al iniciar transacción: %w", err)
	}
	defer tx.Rollback(ctx)

	// Marcar todas las batas como disponibles
	_, err = tx.Exec(ctx, "UPDATE batas SET disponible = true")
	if err != nil {
		return fmt.Errorf("error al actualizar batas: %w", err)
	}

	// Eliminar todas las reservas de prueba
	_, err = tx.Exec(ctx, "DELETE FROM reservas WHERE id_laboratorio = 1")
	if err != nil {
		return fmt.Errorf("error al eliminar reservas: %w", err)
	}

	// Confirmar transacción
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("error al confirmar transacción: %w", err)
	}

	return nil
}
