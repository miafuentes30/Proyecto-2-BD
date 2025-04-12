-- Se crea una base de datos que soporte todos los caracteres especiales
CREATE DATABASE "ddl" WITH ENCODING 'UTF8' TEMPLATE template0;

-- Tabla de tallas disponibles
CREATE TABLE tallas (
    id_talla SERIAL PRIMARY KEY,
    descripcion VARCHAR(5) NOT NULL,
    CONSTRAINT uk_talla_descripcion UNIQUE (descripcion)
);

-- Tabla de estudiantes (User)
CREATE TABLE estudiantes (
    id_estudiante SERIAL PRIMARY KEY,
    matricula VARCHAR(20) NOT NULL,
    nombre VARCHAR(50) NOT NULL,
    apellidos VARCHAR(100) NOT NULL,
    email VARCHAR(100) NOT NULL,
    carrera VARCHAR(100) NOT NULL,
    semestre INTEGER NOT NULL,
    fecha_registro TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_estudiante_matricula UNIQUE (matricula),
    CONSTRAINT uk_estudiante_email UNIQUE (email),
    CONSTRAINT chk_semestre CHECK (semestre > 0 AND semestre <= 12)
);

-- Tabla de laboratorios
CREATE TABLE laboratorios (
    id_laboratorio SERIAL PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    ubicacion VARCHAR(200) NOT NULL,
    capacidad INTEGER NOT NULL,
    CONSTRAINT uk_laboratorio_nombre UNIQUE (nombre),
    CONSTRAINT chk_capacidad CHECK (capacidad > 0)
);

-- Tabla de estados de reserva
CREATE TABLE estados_reserva (
    id_estado SERIAL PRIMARY KEY,
    descripcion VARCHAR(50) NOT NULL,
    CONSTRAINT uk_estado_descripcion UNIQUE (descripcion)
);

-- Tabla de batas
CREATE TABLE batas (
    id_bata SERIAL PRIMARY KEY,
    codigo VARCHAR(20) NOT NULL,
    id_talla INTEGER NOT NULL,
    estado VARCHAR(20) NOT NULL,
    fecha_adquisicion DATE NOT NULL,
    fecha_ultima_revision DATE,
    disponible BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT uk_bata_codigo UNIQUE (codigo),
    CONSTRAINT fk_bata_talla FOREIGN KEY (id_talla) REFERENCES tallas(id_talla),
    CONSTRAINT chk_estado CHECK (estado IN ('Nueva', 'Buena', 'Regular', 'Deteriorada', 'Fuera de servicio'))
);

-- Tabla de reservas
CREATE TABLE reservas (
    id_reserva SERIAL PRIMARY KEY,
    id_estudiante INTEGER NOT NULL,
    id_bata INTEGER NOT NULL,
    id_laboratorio INTEGER NOT NULL,
    id_estado INTEGER NOT NULL,
    fecha_solicitud TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_inicio TIMESTAMP NOT NULL,
    fecha_fin TIMESTAMP NOT NULL,
    observaciones TEXT,
    CONSTRAINT fk_reserva_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiantes(id_estudiante),
    CONSTRAINT fk_reserva_bata FOREIGN KEY (id_bata) REFERENCES batas(id_bata),
    CONSTRAINT fk_reserva_laboratorio FOREIGN KEY (id_laboratorio) REFERENCES laboratorios(id_laboratorio),
    CONSTRAINT fk_reserva_estado FOREIGN KEY (id_estado) REFERENCES estados_reserva(id_estado),
    CONSTRAINT chk_fechas CHECK (fecha_inicio < fecha_fin),
    CONSTRAINT uk_bata_periodo UNIQUE (id_bata, fecha_inicio, fecha_fin)
);


-- Simulación de eventos de laboratorio
CREATE TABLE IF NOT EXISTS eventos_laboratorio (
    id_evento SERIAL PRIMARY KEY,
    nombre VARCHAR(200) NOT NULL,
    id_laboratorio INTEGER NOT NULL,
    fecha_inicio TIMESTAMP NOT NULL,
    fecha_fin TIMESTAMP NOT NULL,
    profesor VARCHAR(100) NOT NULL,
    asignatura VARCHAR(100) NOT NULL,
    cupo_maximo INTEGER NOT NULL,
    CONSTRAINT fk_evento_laboratorio FOREIGN KEY (id_laboratorio) REFERENCES laboratorios(id_laboratorio),
    CONSTRAINT chk_evento_fechas CHECK (fecha_inicio < fecha_fin),
    CONSTRAINT chk_evento_cupo CHECK (cupo_maximo > 0)
);

-- Tabla para asociar estudiantes a eventos (simula los asientos del proyecto)
CREATE TABLE IF NOT EXISTS asistentes_evento (
    id_asistencia SERIAL PRIMARY KEY,
    id_evento INTEGER NOT NULL,
    id_estudiante INTEGER NOT NULL,
    fecha_inscripcion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    asistio BOOLEAN NULL,
    CONSTRAINT fk_asistencia_evento FOREIGN KEY (id_evento) REFERENCES eventos_laboratorio(id_evento),
    CONSTRAINT fk_asistencia_estudiante FOREIGN KEY (id_estudiante) REFERENCES estudiantes(id_estudiante),
    CONSTRAINT uk_evento_estudiante UNIQUE (id_evento, id_estudiante)
);

-- Insertar tallas
INSERT INTO tallas (descripcion) VALUES 
('XS'), ('S'), ('M'), ('L'), ('XL'), ('XXL');

-- Insertar estados de reserva
INSERT INTO estados_reserva (descripcion) VALUES 
('Solicitada'), ('Confirmada'), ('Entregada'), ('Devuelta'), ('Cancelada');

CREATE INDEX idx_reservas_fechas ON reservas (fecha_inicio, fecha_fin);
CREATE INDEX idx_reservas_estudiante ON reservas (id_estudiante);
CREATE INDEX idx_reservas_estado ON reservas (id_estado);
CREATE INDEX idx_batas_disponibilidad ON batas (disponible);

-- Vistas
CREATE OR REPLACE VIEW vista_reservas_activas AS
SELECT 
    r.id_reserva,
    e.matricula,
    e.nombre || ' ' || e.apellidos AS nombre_completo,
    b.codigo AS codigo_bata,
    t.descripcion AS talla_bata,
    l.nombre AS laboratorio,
    er.descripcion AS estado_reserva,
    r.fecha_inicio,
    r.fecha_fin
FROM reservas r
JOIN estudiantes e ON r.id_estudiante = e.id_estudiante
JOIN batas b ON r.id_bata = b.id_bata
JOIN tallas t ON b.id_talla = t.id_talla
JOIN laboratorios l ON r.id_laboratorio = l.id_laboratorio
JOIN estados_reserva er ON r.id_estado = er.id_estado
WHERE r.id_estado IN (1, 2, 3) 
AND r.fecha_fin >= CURRENT_TIMESTAMP;

-- Funcion de disponibilidad
CREATE OR REPLACE FUNCTION verificar_disponibilidad_bata(
    p_id_bata INTEGER,
    p_fecha_inicio TIMESTAMP,
    p_fecha_fin TIMESTAMP)
RETURNS BOOLEAN AS $$
DECLARE
    bata_disponible BOOLEAN;
BEGIN
    -- Verifica si la bata esta disponible o no
    SELECT disponible INTO bata_disponible FROM batas WHERE id_bata = p_id_bata;
    
    IF NOT bata_disponible THEN
        RETURN FALSE;
    END IF;
    
    -- Verificar si no hay una reserva encima de otra
    RETURN NOT EXISTS (
        SELECT 1 FROM reservas
        WHERE id_bata = p_id_bata
        AND id_estado IN (1, 2, 3)
        AND (
            (fecha_inicio <= p_fecha_inicio AND fecha_fin > p_fecha_inicio) OR
            (fecha_inicio < p_fecha_fin AND fecha_fin >= p_fecha_fin) OR
            (fecha_inicio >= p_fecha_inicio AND fecha_fin <= p_fecha_fin)
        )
    );
END;
$$ LANGUAGE plpgsql;

-- Trigger para actualizar disponibilidad de batas cuando cambian las reservas
CREATE OR REPLACE FUNCTION actualizar_disponibilidad_bata() RETURNS TRIGGER AS $$
BEGIN
    -- Si es una nueva reserva y esta confirmada o entregada se marca la bata como no disponible
    IF (TG_OP = 'INSERT' AND NEW.id_estado IN (2, 3)) THEN
        UPDATE batas SET disponible = FALSE WHERE id_bata = NEW.id_bata;
    
    -- Si es actualizacion de estado a devuelta o cancelada se marca la bata como disponible
    ELSIF (TG_OP = 'UPDATE' AND NEW.id_estado IN (4, 5) AND OLD.id_estado IN (2, 3)) THEN
        UPDATE batas SET disponible = TRUE WHERE id_bata = NEW.id_bata;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_actualizar_disponibilidad_bata
AFTER INSERT OR UPDATE ON reservas
FOR EACH ROW EXECUTE FUNCTION actualizar_disponibilidad_bata();

-- Comentarios para que mis compañeros lo puedan entender la BD
COMMENT ON TABLE estudiantes IS 'Almacena información de los estudiantes que pueden realizar reservas';
COMMENT ON TABLE batas IS 'Inventario de batas de laboratorio disponibles para reserva';
COMMENT ON TABLE laboratorios IS 'Información de los laboratorios donde se utilizan las batas';
COMMENT ON TABLE reservas IS 'Registro de todas las reservas de batas realizadas por los estudiantes';
COMMENT ON TABLE estados_reserva IS 'Catálogo de posibles estados de una reserva';
COMMENT ON TABLE tallas IS 'Catálogo de tallas disponibles para las batas';