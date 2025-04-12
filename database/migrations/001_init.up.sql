-- Se consulto a chat gpt 4, corregir la duplicidad de una base de datos en el DocklerFile y brindo lo siguiente (Linea 3-15)

-- Verifica si la base de datos existe antes de crearla
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'ddl') THEN
        CREATE DATABASE "ddl" WITH ENCODING 'UTF8' TEMPLATE template0;
    END IF;
END
$$;

-- Cambia a la base de datos ddl
\c ddl

-- El resto de tu DDL original aquí...



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

-- Insertar estudiantes (usuarios)
INSERT INTO estudiantes (matricula, nombre, apellidos, email, carrera, semestre) VALUES
('A12345', 'María', 'González López', 'maria.gonzalez@universidad.edu', 'Ingeniería Química', 4),
('A12346', 'Carlos', 'Hernández Ruiz', 'carlos.hernandez@universidad.edu', 'Bioquímica', 3),
('A12347', 'Laura', 'Martínez García', 'laura.martinez@universidad.edu', 'Medicina', 6),
('A12348', 'Javier', 'López Torres', 'javier.lopez@universidad.edu', 'Ingeniería Química', 5),
('A12349', 'Ana', 'Sánchez Flores', 'ana.sanchez@universidad.edu', 'Biotecnología', 7),
('A12350', 'Miguel', 'Ramírez Vega', 'miguel.ramirez@universidad.edu', 'Farmacia', 8),
('A12351', 'Sofía', 'Torres Medina', 'sofia.torres@universidad.edu', 'Medicina', 5),
('A12352', 'Daniel', 'Ortiz Blanco', 'daniel.ortiz@universidad.edu', 'Biología', 4),
('A12353', 'Elena', 'Flores Campos', 'elena.flores@universidad.edu', 'Química', 2),
('A12354', 'Pablo', 'Gómez Silva', 'pablo.gomez@universidad.edu', 'Bioquímica', 3);

-- Estudiantes adicionales (IDs 11 al 50)
INSERT INTO estudiantes (matricula, nombre, apellidos, email, carrera, semestre) VALUES
('A12355', 'Lucía', 'Castro Pérez', 'lucia.castro@universidad.edu', 'Medicina', 4),
('A12356', 'Tomás', 'Reyes Gómez', 'tomas.reyes@universidad.edu', 'Bioquímica', 5),
('A12357', 'Valeria', 'Núñez Díaz', 'valeria.nunez@universidad.edu', 'Farmacia', 6),
('A12358', 'Diego', 'Cruz Herrera', 'diego.cruz@universidad.edu', 'Biología', 7),
('A12359', 'Isabella', 'Vargas Soto', 'isabella.vargas@universidad.edu', 'Ingeniería Química', 3),
('A12360', 'Camila', 'Morales León', 'camila.morales@universidad.edu', 'Biotecnología', 4),
('A12361', 'Sebastián', 'Flores Álvarez', 'sebastian.flores@universidad.edu', 'Bioquímica', 5),
('A12362', 'Fernanda', 'Soto Aguilar', 'fernanda.soto@universidad.edu', 'Medicina', 6),
('A12363', 'Andrés', 'Navarro Paredes', 'andres.navarro@universidad.edu', 'Biología', 4),
('A12364', 'Renata', 'García Torres', 'renata.garcia@universidad.edu', 'Farmacia', 3),
('A12365', 'Emiliano', 'Ramos Pérez', 'emiliano.ramos@universidad.edu', 'Ingeniería Química', 5),
('A12366', 'Alexa', 'Cruz Sánchez', 'alexa.cruz@universidad.edu', 'Biotecnología', 6),
('A12367', 'Matías', 'Méndez Romero', 'matias.mendez@universidad.edu', 'Química', 2),
('A12368', 'Nicole', 'Herrera Guzmán', 'nicole.herrera@universidad.edu', 'Medicina', 7),
('A12369', 'Santiago', 'Vega Ramírez', 'santiago.vega@universidad.edu', 'Bioquímica', 6),
('A12370', 'Alejandra', 'Muñoz Cabrera', 'alejandra.munoz@universidad.edu', 'Biología', 5),
('A12371', 'Juan', 'Castillo Molina', 'juan.castillo@universidad.edu', 'Farmacia', 4),
('A12372', 'Mariana', 'Ibarra Ortiz', 'mariana.ibarra@universidad.edu', 'Medicina', 3),
('A12373', 'Gabriel', 'Paz Cordero', 'gabriel.paz@universidad.edu', 'Bioquímica', 2),
('A12374', 'Daniela', 'Silva Duarte', 'daniela.silva@universidad.edu', 'Ingeniería Química', 4),
('A12375', 'Ángel', 'Serrano Franco', 'angel.serrano@universidad.edu', 'Biotecnología', 5),
('A12376', 'Julia', 'Montoya Ríos', 'julia.montoya@universidad.edu', 'Biología', 6),
('A12377', 'Cristóbal', 'Cano Figueroa', 'cristobal.cano@universidad.edu', 'Farmacia', 7),
('A12378', 'Regina', 'Delgado Mejía', 'regina.delgado@universidad.edu', 'Medicina', 8),
('A12379', 'Adrián', 'Zamora Salazar', 'adrian.zamora@universidad.edu', 'Química', 4),
('A12380', 'Ximena', 'Trejo Lozano', 'ximena.trejo@universidad.edu', 'Bioquímica', 3),
('A12381', 'Mauricio', 'Arellano Peña', 'mauricio.arellano@universidad.edu', 'Biotecnología', 6),
('A12382', 'Natalia', 'Correa Valle', 'natalia.correa@universidad.edu', 'Medicina', 7),
('A12383', 'Pedro', 'Luna Campos', 'pedro.luna@universidad.edu', 'Ingeniería Química', 5),
('A12384', 'Samantha', 'Bautista Rangel', 'samantha.bautista@universidad.edu', 'Farmacia', 8),
('A12385', 'Alan', 'Villalobos Bravo', 'alan.villalobos@universidad.edu', 'Biología', 2),
('A12386', 'Valentina', 'Quintana Ponce', 'valentina.quintana@universidad.edu', 'Bioquímica', 3),
('A12387', 'Kevin', 'Ortega Benítez', 'kevin.ortega@universidad.edu', 'Química', 6),
('A12388', 'Andrea', 'Lorenzo Chávez', 'andrea.lorenzo@universidad.edu', 'Ingeniería Química', 4),
('A12389', 'Jorge', 'Solís Padilla', 'jorge.solis@universidad.edu', 'Biotecnología', 5),
('A12390', 'Paulina', 'Zúñiga Herrera', 'paulina.zuniga@universidad.edu', 'Biología', 6),
('A12391', 'Francisco', 'Carrillo Rosas', 'francisco.carrillo@universidad.edu', 'Farmacia', 7),
('A12392', 'Camilo', 'Salinas Gutiérrez', 'camilo.salinas@universidad.edu', 'Medicina', 5),
('A12393', 'Bárbara', 'Reyes Jurado', 'barbara.reyes@universidad.edu', 'Bioquímica', 6),
('A12394', 'Luis', 'Cárdenas Vega', 'luis.cardenas@universidad.edu', 'Química', 3),
('A12395', 'Ana Paula', 'Miranda Navarro', 'ana.miranda@universidad.edu', 'Biología', 2);


-- Insertar laboratorios
INSERT INTO laboratorios (nombre, ubicacion, capacidad) VALUES
('Laboratorio de Química General', 'Edificio A, Planta 1', 30),
('Laboratorio de Bioquímica', 'Edificio B, Planta 2', 25),
('Laboratorio de Microbiología', 'Edificio C, Planta 1', 20),
('Laboratorio de Anatomía', 'Edificio D, Planta 3', 15),
('Laboratorio de Farmacología', 'Edificio B, Planta 3', 25);

-- Insertar batas (ya tenemos las tallas insertadas en el script ddl.sql)
INSERT INTO batas (codigo, id_talla, estado, fecha_adquisicion, fecha_ultima_revision, disponible) VALUES
('B001-XS', 1, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B002-S', 2, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B003-S', 2, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B004-M', 3, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B005-M', 3, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B006-M', 3, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B007-L', 4, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B008-L', 4, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B009-L', 4, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B010-XL', 5, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B011-XL', 5, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B012-XXL', 6, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B013-XS', 1, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B014-S', 2, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B015-M', 3, 'Deteriorada', '2022-11-10', '2024-03-15', TRUE),
('B016-L', 4, 'Deteriorada', '2022-11-10', '2024-03-15', FALSE),
('B017-XL', 5, 'Fuera de servicio', '2022-06-05', '2024-03-15', FALSE),
('B018-XXL', 6, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B019-M', 3, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B020-L', 4, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B021-XL', 5, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B022-XL', 5, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B023-XXL', 6, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B024-XS', 1, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B025-S', 2, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B026-M', 3, 'Deteriorada', '2022-11-10', '2024-03-15', TRUE),
('B027-L', 4, 'Deteriorada', '2022-11-10', '2024-03-15', FALSE),
('B028-XL', 5, 'Fuera de servicio', '2022-06-05', '2024-03-15', FALSE),
('B029-XXL', 6, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B030-M', 3, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B031-L', 4, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B032-XS', 1, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B033-S', 2, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B034-S', 2, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B035-M', 3, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B036-M', 3, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B037-M', 3, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B038-L', 4, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B039-L', 4, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B040-L', 4, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B041-XL', 5, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B042-XL', 5, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B043-XXL', 6, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B044-XS', 1, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B045-S', 2, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B046-M', 3, 'Deteriorada', '2022-11-10', '2024-03-15', TRUE),
('B047-L', 4, 'Deteriorada', '2022-11-10', '2024-03-15', FALSE),
('B048-XL', 5, 'Fuera de servicio', '2022-06-05', '2024-03-15', FALSE),
('B049-XXL', 6, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B050-M', 3, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B051-L', 4, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B052-XS', 1, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B053-S', 2, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B054-S', 2, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B055-M', 3, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B056-M', 3, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B057-M', 3, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B058-L', 4, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B059-L', 4, 'Buena', '2023-09-20', '2024-03-15', TRUE),
('B060-L', 4, 'Regular', '2023-05-15', '2024-03-15', TRUE),
('B061-XL', 5, 'Nueva', '2024-01-10', '2024-03-15', TRUE),
('B062-XL', 5, 'Buena', '2023-09-20', '2024-03-15', TRUE);

-- Insertar eventos de laboratorio
INSERT INTO eventos_laboratorio (nombre, id_laboratorio, fecha_inicio, fecha_fin, profesor, asignatura, cupo_maximo) VALUES
('Práctica Identificación de Compuestos', 1, '2025-04-15 09:00:00', '2025-04-15 12:00:00', 'Dr. Martínez', 'Química Orgánica', 25),
('Práctica Análisis de Proteínas', 2, '2025-04-16 10:00:00', '2025-04-16 13:00:00', 'Dra. Rodríguez', 'Bioquímica Avanzada', 20),
('Práctica Cultivo de Bacterias', 3, '2025-04-17 14:00:00', '2025-04-17 17:00:00', 'Dr. López', 'Microbiología', 15),
('Práctica Disección', 4, '2025-04-18 09:00:00', '2025-04-18 13:00:00', 'Dra. García', 'Anatomía', 12),
('Práctica Síntesis de Medicamentos', 5, '2025-04-21 10:00:00', '2025-04-21 14:00:00', 'Dr. Sánchez', 'Farmacología', 20);


-- Insertar asistentes a eventos (estudiantes en practicas)
INSERT INTO asistentes_evento (id_evento, id_estudiante) VALUES
(1, 1), (1, 4), (1, 9), -- Quimica: María, Javier, Elena
(2, 2), (2, 5), (2, 10), -- Bioquimica: Carlos, Ana, Pablo
(3, 3), (3, 7), --  Microbilogia: Laura, Sofía
(4, 3), (4, 7), -- Anatomia: Laura, Sofía
(5, 5), (5, 6); -- Farma: Ana, Miguel

-- Insertar reservas de batas
INSERT INTO reservas (id_estudiante, id_bata, id_laboratorio, id_estado, fecha_solicitud, fecha_inicio, fecha_fin, observaciones) VALUES
-- Reservas para la práctica de qumiica
(1, 4, 1, 2, '2025-04-01 10:15:30', '2025-04-15 08:30:00', '2025-04-15 12:30:00', 'Reserva para práctica de Identificación de Compuestos'),
(4, 8, 1, 2, '2025-04-01 11:20:15', '2025-04-15 08:30:00', '2025-04-15 12:30:00', 'Reserva para práctica de Identificación de Compuestos'),
(9, 14, 1, 1, '2025-04-02 09:05:40', '2025-04-15 08:30:00', '2025-04-15 12:30:00', 'Pendiente de confirmación'),

-- Reservas para la práctica de bioquimica
(2, 3, 2, 2, '2025-04-03 14:25:10', '2025-04-16 09:30:00', '2025-04-16 13:30:00', 'Reserva para práctica de Análisis de Proteínas'),
(5, 5, 2, 2, '2025-04-03 15:40:20', '2025-04-16 09:30:00', '2025-04-16 13:30:00', 'Reserva para práctica de Análisis de Proteínas'),
(10, 19, 2, 1, '2025-04-04 10:15:30', '2025-04-16 09:30:00', '2025-04-16 13:30:00', 'Pendiente de confirmación'),

-- Reservas para la práctica de microbiologia
(3, 7, 3, 3, '2025-04-05 11:30:45', '2025-04-17 13:30:00', '2025-04-17 17:30:00', 'Bata ya entregada para práctica'),
(7, 9, 3, 2, '2025-04-05 12:10:25', '2025-04-17 13:30:00', '2025-04-17 17:30:00', 'Confirmada, pendiente de entrega'),

-- Reservas para la práctica de anatomonia
(3, 7, 4, 4, '2025-04-10 09:20:15', '2025-04-18 08:30:00', '2025-04-18 13:30:00', 'Bata devuelta en buen estado'),
(7, 9, 4, 5, '2025-04-10 10:05:30', '2025-04-18 08:30:00', '2025-04-18 13:30:00', 'Reserva cancelada por el estudiante'),

-- Reservas para la práctica de farma
(5, 10, 5, 1, '2025-04-12 14:15:30', '2025-04-21 09:30:00', '2025-04-21 14:30:00', 'Solicitada talla XL'),
(6, 12, 5, 1, '2025-04-12 15:20:40', '2025-04-21 09:30:00', '2025-04-21 14:30:00', 'Solicitada talla XXL');

-- Insertar algunas reservas adicionales para otras fechas
INSERT INTO reservas (id_estudiante, id_bata, id_laboratorio, id_estado, fecha_solicitud, fecha_inicio, fecha_fin, observaciones) VALUES
(8, 1, 2, 2, '2025-04-02 10:30:20', '2025-04-22 09:00:00', '2025-04-22 12:00:00', 'Práctica individual'),
(9, 2, 1, 2, '2025-04-03 11:45:30', '2025-04-23 14:00:00', '2025-04-23 17:00:00', 'Proyecto especial de química'),
(10, 6, 2, 1, '2025-04-04 16:20:10', '2025-04-24 10:00:00', '2025-04-24 13:00:00', 'Investigación para tesis');

-- Actualizamos los estados de las batas que están reservadas para reflejar su disponibilidad
UPDATE batas SET disponible = TRUE WHERE id_bata IN (
    SELECT id_bata FROM reservas WHERE id_estado IN (2, 3)
);
