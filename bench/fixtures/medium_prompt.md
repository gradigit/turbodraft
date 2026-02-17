# REST API Design Guide

Build a **RESTful API** for a task management system with the following endpoints and behaviors.

## Authentication

All endpoints require a `Bearer` token in the `Authorization` header. Tokens are *JWTs* with a 1-hour expiry. Use the `HS256` algorithm with a server-side secret.

### Token Format

```json
{
  "sub": "user_123",
  "iat": 1708214400,
  "exp": 1708218000,
  "roles": ["user", "admin"]
}
```

## Endpoints

### GET /tasks

Returns a paginated list of tasks for the authenticated user.

**Query Parameters:**

| Parameter | Type     | Default | Description            |
|-----------|----------|---------|------------------------|
| `page`    | integer  | 1       | Page number            |
| `limit`   | integer  | 20      | Items per page (max 100) |
| `status`  | string   | all     | Filter: `pending`, `done`, `all` |
| `sort`    | string   | created | Sort by: `created`, `updated`, `priority` |

**Response** (`200 OK`):

```json
{
  "tasks": [
    {
      "id": "task_abc123",
      "title": "Review PR #42",
      "status": "pending",
      "priority": "high",
      "created_at": "2026-02-17T10:00:00Z",
      "updated_at": "2026-02-17T12:30:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "limit": 20,
    "total": 147,
    "has_next": true
  }
}
```

### POST /tasks

Create a new task.

**Request Body:**

```json
{
  "title": "Deploy v2.1",
  "description": "Roll out the new caching layer to production.",
  "priority": "high",
  "due_date": "2026-02-20T17:00:00Z",
  "tags": ["deployment", "infrastructure"]
}
```

**Validation Rules:**

- `title` is **required**, 1–200 characters
- `priority` must be one of: `low`, `medium`, `high`, `critical`
- `due_date` must be in the future (if provided)
- `tags` is optional, max 10 tags, each 1–50 chars

### PUT /tasks/:id

Update an existing task. Supports partial updates.

### DELETE /tasks/:id

Soft-delete a task (sets `deleted_at` timestamp). Returns `204 No Content`.

## Error Handling

All errors follow [RFC 7807](https://tools.ietf.org/html/rfc7807):

```json
{
  "type": "https://api.example.com/errors/validation",
  "title": "Validation Error",
  "status": 422,
  "detail": "Field 'title' is required and cannot be empty.",
  "instance": "/tasks"
}
```

### Status Codes

- `400` — Bad request (malformed JSON)
- `401` — Missing or invalid token
- `403` — Insufficient permissions
- `404` — Resource not found
- `422` — Validation error
- `429` — Rate limit exceeded (100 req/min per user)
- `500` — Internal server error

## Rate Limiting

- **Limit**: 100 requests per minute per authenticated user
- **Headers**: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`
- Exceeding the limit returns `429` with a `Retry-After` header

## Database Schema

```sql
CREATE TABLE tasks (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  title       TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 200),
  description TEXT,
  status      TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','done')),
  priority    TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('low','medium','high','critical')),
  due_date    TIMESTAMP,
  tags        JSONB DEFAULT '[]',
  created_at  TIMESTAMP NOT NULL DEFAULT now(),
  updated_at  TIMESTAMP NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMP
);

CREATE INDEX idx_tasks_user_status ON tasks(user_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_created ON tasks(user_id, created_at DESC);
```

## Acceptance Criteria

- [ ] All endpoints return proper status codes
- [ ] Pagination works correctly at boundaries
- [ ] Rate limiting is enforced per-user
- [x] Soft delete preserves data
- [ ] JWT validation rejects expired tokens
- [ ] Input validation returns descriptive errors

> **Important**: Never expose internal error details (stack traces, SQL) in production responses.
> Use structured logging with correlation IDs for debugging.

---

*Benchmark fixture — exercises tables, nested code blocks, links, and mixed formatting.*
