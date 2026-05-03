# ADR-004: Arquitectura de la Aplicación (Controller-PORO-Serializer-Policy)

**Fecha:** 2026-04-03  
**Estado:** Aceptado

---

## Contexto

El proyecto necesita una arquitectura que mantenga los controllers finos, separe la lógica de negocio del framework, y sea clara en cuanto a dónde vive cada responsabilidad. Rails por defecto no impone separación entre lógica de negocio y modelos, lo que lleva a "fat models" difíciles de testear y mantener a medida que el sistema crece.

## Decisión

Se adopta una arquitectura en capas con **POROs (Plain Old Ruby Objects)** como capa de lógica de negocio:

```
Request
  → ApplicationController (auth + tenant)
    → Controller específico (orquestar: delegar a PORO, serializar)
      → PORO (lógica de negocio: un caso de uso por clase)
        → Model (persistencia, validaciones, relaciones)
      → Serializer (formato JSON de respuesta)
      → Policy (reglas de autorización)
  → Response
```

### Estructura de carpetas

```
app/
├── controllers/
│   ├── application_controller.rb   # Auth + tenant + error handling global
│   └── api/
│       └── v1/                     # Versión de la API
│           └── [recurso]_controller.rb
│
├── models/
│   ├── application_record.rb       # Global Default Scope de multi-tenancy
│   └── [entidad].rb
│
├── poros/
│   ├── application_poro.rb         # Base class
│   └── [dominio]/
│       └── [caso_de_uso].rb        # Un PORO = un caso de uso
│
├── serializers/
│   ├── application_serializer.rb   # Base Blueprinter
│   └── [entidad]_serializer.rb
│
├── policies/
│   ├── application_policy.rb       # Base Pundit
│   └── [entidad]_policy.rb
│
└── jobs/
    ├── application_job.rb          # Base Solid Queue
    └── [dominio]/
        └── [job_name]_job.rb
```

### Reglas de responsabilidad

| Capa        | Puede hacer                                   | No puede hacer                              |
| ----------- | --------------------------------------------- | ------------------------------------------- |
| Controller  | Autenticar, autorizar, parsear params, serializar | Lógica de negocio, queries directas         |
| PORO        | Lógica de negocio, orquestar models/jobs      | Renderizar JSON, acceder a `params`/`request` |
| Model       | Validaciones, relaciones, scopes simples      | Lógica de negocio compleja, HTTP            |
| Serializer  | Formatear JSON de respuesta                   | Lógica de negocio                           |
| Policy      | Verificar permisos de autorización            | Lógica de negocio                           |
| Job         | Trabajo asíncrono en background               | Responder requests HTTP                     |

## Alternativas consideradas

### Fat Models (lógica en los modelos)

- ✅ Convención de Rails — sin capas adicionales
- ❌ Los modelos crecen indefinidamente y se vuelven difíciles de testear
- ❌ Dificulta reusar lógica de negocio fuera del contexto de un model

### Service Objects con nombre genérico

- ✅ Separa la lógica de los modelos
- ❌ El término "service" es ambiguo — no queda claro qué hay en cada clase

### Dry-rb / ROM (Ruby Object Mapper)

- ✅ Arquitectura funcional sólida, inmutabilidad
- ❌ Ruptura total con las convenciones Rails
- ❌ Curva de aprendizaje muy pronunciada

## Consecuencias

- ✅ Los controllers son finos y fáciles de leer: solo orquestan
- ✅ Los POROs son testeables en aislamiento (sin Rails, sin DB si no es necesario)
- ✅ La lógica de negocio vive en un lugar predecible: `app/poros/[dominio]/`
- ✅ Cada capa tiene una única responsabilidad clara
- ⚠️ Requiere disciplina: es tentador poner lógica en models o controllers
- ⚠️ Más archivos que una arquitectura Rails tradicional — compensado por la claridad
