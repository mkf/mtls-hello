# Contract: HTTP Endpoints Under Apache

**Feature**: Apache HTTP Server Backend
**Date**: 2026-08-06

## Overview

The project exposes the same HTTP endpoints as before, but they are served by Apache via CGI. The contract for request path, query parameters, request body, and response body remains unchanged. The trust evaluation is performed by the CGI handler, not by Apache.

## Trust precondition

- For all endpoints, the handler must first evaluate the client certificate.
- If the client is untrusted, the handler returns HTTP 401 and may capture the certificate in purgatory.
- The exception is the capture endpoint logic, which intentionally runs for untrusted clients.

## Endpoints

### GET /:path

- **Handler**: `handlers/<path>.get.sh` (if it exists) or a default echo handler.
- **Request**: No body.
- **Response**: `text/plain` body containing the path segment (or custom output from the handler script).
- **Example**: `GET /hello` → `hello`.

### POST /bundle

- **Handler**: `handlers/bundle.post.sh`.
- **Request body**: raw Git bundle bytes.
- **Query parameters**: `repo` (repository name), optionally `from` and `to` commit SHAs.
- **Response**: `200 OK` with text `spooled`.
- **Behavior**: The bundle is saved to `<data-dir>/spool/<repo>/<from>-<to>.bundle`. The bare repository is not modified.

### GET /spool

- **Handler**: `handlers/spool.get.sh`.
- **Query parameters**: `repo` (repository name).
- **Response**: JSON object mapping covered commit ranges to their filenames.
- **Example**: `GET /spool?repo=laptops` → `{"abc-def":"abc-def.bundle"}`.

### HEAD /head

- **Handler**: `handlers/head.get.sh`.
- **Response**: JSON describing the repository heads for the requested repo.

## Response statuses

- `200 OK`: Request succeeded and the client is trusted.
- `401 Unauthorized`: Client certificate is untrusted or missing. The response body may be `Untrusted`.
- `404 Not Found`: Handler script does not exist for the requested path/method.
- `500 Internal Server Error`: Handler script failed.
- `507 Insufficient Storage`: Disk full during bundle spool write.
