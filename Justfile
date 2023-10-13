help:
	just -l

cizero:
	zig build

# Run in `nix develop .#devShells.x86_64-linux.crystal`
hello:
	nix develop .#devShells.x86_64-linux.crystal --command just hello-unwrapped

hello-unwrapped:
	crystal build ./plugins/hello/hello.cr -o hello.wasm --error-trace --verbose --cross-compile --target wasm32-wasi
	wasm-ld hello.wasm -o hello -Lwasi-libs -lc -lpcre2-8
