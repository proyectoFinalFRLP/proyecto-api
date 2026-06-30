# Git workflow

## 1. Ramas

**Formato requerido:**

```
TESIS-<número>-<descripción-corta-en-kebab-case>
```

**Ramas especiales permitidas:** `master`, `develop`, `staging`, `hotfix/*`, `release/*`

```
TESIS-25-user-authentication
TESIS-32-product-catalog-model
TESIS-36-webhook-gateway-endpoint
```

El formato es validado localmente en el hook `pre-push` (Lefthook) y en el CI de GitHub Actions en cada PR.

---

## 2. Commits (Conventional Commits)

**Formato:** `<tipo>: <descripción en inglés>`

| Tipo       | Cuándo usarlo                                       |
| ---------- | --------------------------------------------------- |
| `feat`     | Nueva funcionalidad                                 |
| `fix`      | Corrección de bug                                   |
| `refactor` | Cambio de código sin nueva feature ni bug fix       |
| `style`    | Cambios de formato o espaciado (sin lógica)         |
| `docs`     | Cambios en documentación                            |
| `chore`    | Mantenimiento (dependencias, configuraciones, etc.) |
| `test`     | Agregar o modificar tests                           |
| `perf`     | Mejoras de rendimiento                              |

**Reglas:**

- Descripción en **inglés**
- Modo **imperativo** ("add", no "added" ni "adds")
- Sin mayúscula inicial en la descripción
- Sin punto al final
- Máximo **100 caracteres** en la primera línea

```
feat: add order model with status lifecycle
fix: correct stock deduction on order confirmation
refactor: extract courier quote logic to PORO
docs: add architecture guidelines
chore: upgrade blueprinter to v1.2
test: add request spec for product index
```

El formato es validado en el hook `commit-msg` por Lefthook.

---

## 3. Pull Requests

**Título:** `<tipo>: [TESIS-XXX] short description in english`

```
feat: [TESIS-25] add user authentication with JWT
fix: [TESIS-38] prevent race condition on stock update
docs: [TESIS-12] add backend architecture guidelines
```

**Reglas:**

- 1 PR por card de Jira
- El PR debe pasar build (`bundle exec rspec`) y lint (`bundle exec rubocop`) antes de solicitar review
- Mínimo **1 aprobación** requerida para hacer merge
- No mergear a `master` sin PR aprobado
- Si el PR introduce un nuevo patrón o decisión arquitectural, actualizar o crear el ADR correspondiente en `docs/adr/`

La plantilla de descripción en `.github/pull_request_template.md` se carga automáticamente al abrir un PR. Incluye: link al ticket Jira, descripción, cambios realizados, evidencia (si aplica), cómo probar e impacto.

---

## 4. Flujo de trabajo

```
master
  └── TESIS-123-feature-name   ← branch por card
        └── commits atómicos y descriptivos
              └── PR: feat: [TESIS-123] feature name
                    └── code review → merge a master
```

---

## 5. Hooks de Git (Lefthook)

| Hook         | Acción                                               |
| ------------ | ---------------------------------------------------- |
| `pre-commit` | RuboCop sobre archivos `.rb` staged                  |
| `commit-msg` | Valida el formato del mensaje de commit              |
| `pre-push`   | RSpec completo + validación del nombre de rama       |

El hook `pre-commit` corre RuboCop en paralelo solo sobre los archivos staged, lo que lo hace rápido.

El hook `pre-push` corre `bundle exec rspec` completo: asegura que ningún push rompa los tests.

---

## 6. CI/CD (GitHub Actions)

Pipeline en `.github/workflows/ci.yml`. Se dispara en push y pull_request sobre `main`, `master` y `develop`.

| Job        | Acción                                           | Dependencia |
| ---------- | ------------------------------------------------ | ----------- |
| `security` | Brakeman + Bundler-audit                         | —           |
| `lint`     | RuboCop                                          | —           |
| `test`     | RSpec con servicio PostgreSQL efímero            | —           |

Los tres jobs corren en paralelo. Un PR no puede mergearse hasta que los tres estén en verde.

**Workflow adicionales:**

- `auto-assign-reviewer.yml`: asigna reviewers automáticamente al abrir un PR
- `pr-title.yml`: valida el formato del título del PR

---

## 7. Comandos útiles

```bash
# Ver rama actual
git branch --show-current

# Crear rama para una card
git checkout -b TESIS-XXX-descripcion-feature

# Verificar antes de hacer push
bundle exec rubocop
bundle exec rspec

# Push de la rama
git push -u origin TESIS-XXX-descripcion-feature
```
