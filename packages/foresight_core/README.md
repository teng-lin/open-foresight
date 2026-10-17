# Foresight core

Flutter-independent application operations, persistence, retrieval/inference adapters, imports, Google connections, and meeting lifecycle.

`bin/service.dart` hosts one profile on a private Unix socket. `bin/mcp.dart` exposes its operations over MCP stdio. `remote.dart` provides the desktop facade; its SQLite connection is read-only.

See [application service documentation](../../docs/architecture/application-service.md) and [implementation plan](../../docs/archive/application-service-plan.md).
