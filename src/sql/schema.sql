CREATE TABLE "plugin" (
	"name" TEXT PRIMARY KEY,
	"wasm" BLOB NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE "callback" (
	"id" INTEGER PRIMARY KEY,
	"plugin" TEXT NOT NULL REFERENCES "plugin" ON DELETE CASCADE,
	"function" TEXT NOT NULL,
	"user_data" BLOB
) STRICT;

CREATE TABLE "timeout_callback" (
	"callback" INTEGER PRIMARY KEY REFERENCES "callback" ON DELETE CASCADE,
	"timestamp" INTEGER NOT NULL,
	"cron" TEXT
) STRICT;

CREATE INDEX "timeout_callback.timestamp" ON "timeout_callback" ("timestamp");

CREATE TABLE "http_callback" (
	"callback" INTEGER PRIMARY KEY REFERENCES "callback" ON DELETE CASCADE,
	"plugin" TEXT NOT NULL UNIQUE REFERENCES "plugin"
) STRICT;

CREATE TABLE "nix_build_callback" (
	"callback" INTEGER PRIMARY KEY REFERENCES "callback" ON DELETE CASCADE,
	"installable" TEXT NOT NULL
) STRICT;

CREATE TABLE "nix_eval_callback" (
	"callback" INTEGER PRIMARY KEY REFERENCES "callback" ON DELETE CASCADE,
	"flake" TEXT,
	"expr" TEXT NOT NULL,
	"format" INTEGER NOT NULL CHECK ("format" BETWEEN 0 AND 2)
) STRICT;
