NASM      := nasm
# Cross-section absolute relocations are how a non-PIE flat binary refers to
# its own .data/.bss; nasm 3.x warns about them by default, ld resolves them.
NASMFLAGS := -f elf64 -g -F dwarf -Wall -w-reloc-rel-dword -w-reloc-abs-qword -w-reloc-abs-dword
LD        := ld
# Dynamic solely for libsodium (Argon2id); everything else is raw syscalls.
# The loader path follows the host libc: musl (Alpine) or glibc.
DYNLINK   ?= $(shell test -e /lib/ld-musl-x86_64.so.1 && echo /lib/ld-musl-x86_64.so.1 || echo /lib64/ld-linux-x86-64.so.2)
LDFLAGS   := -z noexecstack -z relro -z now -dynamic-linker $(DYNLINK)
LDLIBS    := -lsodium

SRC := src/main.asm src/net.asm src/http.asm src/threads.asm src/util.asm \
       src/store.asm src/crypto.asm src/cli.asm src/tmpl.asm src/pages.asm \
       src/auth.asm src/md.asm src/admin.asm src/seccomp.asm src/i18n.asm
OBJ := $(patsubst src/%.asm,build/%.o,$(SRC))

all: build/blogd static/main.css

css: static/main.css

static/main.css: assets/input.css $(wildcard templates/*/*.html) tools/tailwindcss
	tools/tailwindcss -i assets/input.css -o static/main.css --minify
	gzip -9 -kf static/main.css
	@command -v brotli >/dev/null 2>&1 && brotli -kf -q 11 static/main.css || true

icons:
	python3 tools/mkicons.py

build:
	mkdir -p build

build/%.o: src/%.asm src/sys.inc src/conn.inc src/store.inc | build
	$(NASM) $(NASMFLAGS) $< -o $@

build/blogd: $(OBJ)
	$(LD) $(LDFLAGS) -o $@ $(OBJ) $(LDLIBS)

run: all
	./build/blogd

test: all
	./tests/smoke.sh

fuzz: all
	./tests/fuzz.sh

image:
	docker build -t blogd .

clean:
	rm -rf build static/main.css static/main.css.gz static/main.css.br

.PHONY: all css icons run test fuzz image clean
