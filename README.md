# Proyecto API

## Descripción

API REST desarrollada en Ruby on Rails como parte del proyecto final.

El objetivo de esta aplicación es "".

## Tecnologías utilizadas

- Ruby on Rails (API mode)
- PostgreSQL
- Devise + Devise JWT (autenticación)
- Pundit (autorización)
- Rubocop (calidad de código)

## Arquitectura del proyecto

El proyecto sigue una arquitectura desacoplada basada en:

- **Controllers** → Manejo de requests HTTP (sin lógica de negocio)
- **Models** → Persistencia con ActiveRecord
- **POROs** → Lógica de negocio (casos de uso)
- **Serializers** → Formato de respuesta JSON
- **Policies** → Autorización mediante Pundit

## Setup del proyecto

### 1. Clonar repositorio

git clone https://github.com/proyectoFinalFRLP/proyecto-api.git

cd proyecto-api

### 2. Instalar dependencias

bundle install

### 3. Crear base de datos

rails db:create

### 4. Ejecutar migraciones

rails db:migrate

### 5. Crear seed

rails db:seed

### 6. Iniciar servidor

rails server

## Calidad de código

El proyecto utiliza Rubocop para mantener estándares de código consistentes.

Ejecutar: 

bundle exec rubocop
