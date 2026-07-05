# ADR-001: Backend Stack

**Fecha:** 2026-04-03  
**Estado:** Aceptado

---

## Contexto

Este proyecto es el backend de una aplicación web para el trabajo final de la carrera de Ingeniería en Sistemas de Información. Se requiere construir una API REST que sirva como OMS (Order Management System) multi-tenant, consumida por un frontend React. Se necesita un stack con soporte a largo plazo, buena gestión de base de datos relacional, y ecosistema maduro para APIs.

## Decisión

Se adopta el siguiente stack base:

| Tecnología  | Versión | Rol                     |
| ----------- | ------- | ----------------------- |
| **Ruby**    | 4.0.2   | Lenguaje                |
| **Rails**   | 8.1.2.1 | Framework (API-only)    |
| **PostgreSQL** | —    | Base de datos principal |
| **Puma**    | 7.2.0   | Servidor web            |

Rails se configura en modo **API-only** (`config.api_only = true`), eliminando middleware de sesiones, cookies y rendering de vistas.

## Alternativas consideradas

### Sinatra / Hanami

- ✅ Más liviano y minimalista
- ❌ Ecosistema más reducido para un sistema complejo con múltiples dominios
- ❌ Menor convención: más decisiones de arquitectura manuales
- ❌ El equipo tiene mayor familiaridad con Rails

### Node.js (Express / Fastify)

- ✅ Mismo lenguaje que el frontend (JavaScript/TypeScript)
- ❌ El modelo de concurrencia async puede complicar la lógica de negocio sincrónica
- ❌ El ORM (Sequelize/Prisma) es menos maduro que ActiveRecord para relaciones complejas
- ❌ El equipo tiene mayor experiencia con Ruby/Rails

### MySQL en lugar de PostgreSQL

- ✅ Más simple para setups de desarrollo
- ❌ PostgreSQL ofrece mejor soporte para JSON, arrays, índices parciales y extensiones útiles para este dominio
- ❌ Kamal y el stack de producción ya están configurados para PostgreSQL

## Consecuencias

- ✅ Rails provee convenciones sólidas (ActiveRecord, routing, validaciones) que aceleran el desarrollo
- ✅ Rails 8.1 incluye Solid Queue, Solid Cache y Solid Cable de forma nativa, reduciendo dependencias externas
- ✅ El modo API-only elimina overhead innecesario (sin vistas, sin cookies)
- ✅ PostgreSQL soporta las queries complejas necesarias para un OMS multi-tenant
- ⚠️ Rails es opinionado: apartarse de las convenciones tiene un costo mayor que en frameworks minimalistas
