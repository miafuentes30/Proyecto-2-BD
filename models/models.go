package models

import "time"

type Estudiante struct {
	ID            int
	Matricula     string
	Nombre        string
	Apellidos     string
	Email         string
	Carrera       string
	Semestre      int
	FechaRegistro time.Time
}

type Bata struct {
	ID               int
	Codigo           string
	IDTalla          int
	Estado           string
	Disponible       bool
	FechaAdquisicion time.Time
}

type Reserva struct {
	ID             int
	IDEstudiante   int
	IDBata         int
	IDLaboratorio  int
	IDEstado       int
	FechaSolicitud time.Time
	FechaInicio    time.Time
	FechaFin       time.Time
}
