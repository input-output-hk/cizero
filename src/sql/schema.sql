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
) STRICT, WITHOUT ROWID;

CREATE INDEX "timeout_callback.timestamp" ON "timeout_callback" ("timestamp");

CREATE TABLE "http_callback" (
	"callback" INTEGER PRIMARY KEY REFERENCES "callback" ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
