from pathlib import Path
import shutil
import json
import sys

base = Path(sys.argv[1]).resolve()
dest = Path(sys.argv[2]).resolve()
overlay = Path(sys.argv[3]).resolve()
# Refuse an existing destination rather than modifying an unknown fixture.
dest.mkdir(mode=0o700)
for name in ["pubspec.yaml", "pubspec.lock"]:
    shutil.copy2(base / name, dest / name)
support = dest.parent / "foresight_test_support"
if support.exists():
    if not support.samefile(base.parent / "foresight_test_support"):
        raise ValueError("Existing test-support path belongs to another fixture")
else:
    support.symlink_to(base.parent / "foresight_test_support", target_is_directory=True)
shutil.copytree(base / "lib", dest / "lib", dirs_exist_ok=True)
shutil.copytree(base / "test", dest / "test", dirs_exist_ok=True)
conf = json.loads((base / ".dart_tool/package_config.json").read_text())
for p in conf["packages"]:
    if p["name"] == "foresight_core":
        p["rootUri"] = dest.as_uri() + "/"
    elif not p["rootUri"].startswith("file:"):
        p["rootUri"] = (base / ".dart_tool" / p["rootUri"]).resolve().as_uri() + "/"
(dest / ".dart_tool").mkdir(exist_ok=True)
(dest / ".dart_tool/package_config.json").write_text(json.dumps(conf))
p = dest / "lib/src/sqlite_read_worker.dart"
s = (
    p.read_text()
    .replace(
        "import 'sqlite_read_session.dart';",
        "import 'sqlite_read_session.dart';\nimport 'persistence/sqlite_statement_budget.dart';",
    )
    .replace(
        "  SqliteReadSession session;",
        "  initializeSqlDeadlineSupport();\n  SqliteReadSession session;",
    )
)
p.write_text(s)
for name in [
    "test/fixtures/sqlite_reader_owner_exit.dart",
    "test/sqlite_statement_budget_test.dart",
    "test/sqlite_read_worker_budget_test.dart",
    "test/sqlite_store_reader_test.dart",
    "test/read_coordinator_test.dart",
    "test/sqlite_runtime_test.dart",
]:
    p = dest / name
    s = p.read_text()
    s = (
        "import 'package:foresight_core/src/persistence/sqlite_statement_budget.dart';\n"
        + s
        if "sqlite_statement_budget.dart" not in s
        else s
    )
    if name.endswith("owner_exit.dart"):
        s = s.replace(
            "Future<void> main(List<String> args) async {",
            "Future<void> main(List<String> args) async {\n  initializeSqlDeadlineSupport();",
        )
    else:
        s = s.replace(
            "void main() {", "void main() {\n  initializeSqlDeadlineSupport();"
        ).replace(
            "      installServiceWorkerEnvironment(environment);",
            "      installServiceWorkerEnvironment(environment);\n      initializeSqlDeadlineSupport();",
        )
    p.write_text(s)

shutil.copy2(overlay, dest / "lib/src/persistence/sqlite_statement_budget.dart")
