NASM      := nasm
# Cross-section absolute relocations are how a non-PIE flat binary refers to
# its own .data/.bss; nasm 3.x warns about them by default, ld resolves them.
# The warning names do not exist in nasm 2.x (RHEL/Alma/Rocky, Debian
# stable), so they are only passed when this nasm accepts them.
NASM_RELOC_W := -w-reloc-rel-dword -w-reloc-abs-qword -w-reloc-abs-dword
NASM_PROBE   := $(shell mkdir -p build && printf 'BITS 64\n' > build/probe.asm && echo build/probe.asm)
NASM_RELOC_W := $(shell $(NASM) -f elf64 $(NASM_RELOC_W) $(NASM_PROBE) -o build/probe.o 2>&1 | grep -q unknown-warning || echo $(NASM_RELOC_W))
NASMFLAGS := -f elf64 -g -F dwarf -Wall $(NASM_RELOC_W)
LD        := ld
# Dynamic solely for libsodium (Argon2id); everything else is raw syscalls.
# The loader path follows the host libc: musl (Alpine) or glibc.
DYNLINK   ?= $(shell test -e /lib/ld-musl-x86_64.so.1 && echo /lib/ld-musl-x86_64.so.1 || echo /lib64/ld-linux-x86-64.so.2)
LDFLAGS   := -z noexecstack -z relro -z now -dynamic-linker $(DYNLINK)
LDLIBS    := -lsodium

SRC := src/main.asm src/net.asm src/http.asm src/threads.asm src/util.asm \
       src/store.asm src/crypto.asm src/cli.asm src/tmpl.asm src/pages.asm \
       src/auth.asm src/md.asm src/admin.asm src/seccomp.asm src/i18n.asm \
       src/pcache.asm src/media.asm src/signal.asm src/reload.asm src/log.asm
OBJ := $(patsubst src/%.asm,build/%.o,$(SRC))

all: build/blogd static/main.css

css: static/main.css

# One stylesheet per theme (static/main.css is retro, static/<theme>-main.css
# the rest), each with .gz/.br siblings. tools/mkcss.py splits input.css at
# the THEME banners and runs Tailwind once per theme; brotli is required.
static/main.css: assets/input.css $(wildcard templates/*/*.html) tools/tailwindcss tools/mkcss.py
	python3 tools/mkcss.py

# The Tailwind standalone CLI is gitignored; a fresh clone fetches the
# pinned release and verifies its checksum (the same pins CI and the
# Dockerfile use — bump all three together).
TAILWIND_VERSION      := v4.3.3
TAILWIND_SHA256_GLIBC := dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a
TAILWIND_SHA256_MUSL  := a04d34ceacc8f52cbe8920ad846cdeb61d3d0021dba32db0d1f77c9d9fad7a6c
TAILWIND_FLAVOUR      := $(shell test -e /lib/ld-musl-x86_64.so.1 && echo musl || echo glibc)
TAILWIND_ASSET        := $(if $(filter musl,$(TAILWIND_FLAVOUR)),tailwindcss-linux-x64-musl,tailwindcss-linux-x64)
TAILWIND_SHA256       := $(if $(filter musl,$(TAILWIND_FLAVOUR)),$(TAILWIND_SHA256_MUSL),$(TAILWIND_SHA256_GLIBC))

tools/tailwindcss:
	@echo "fetching Tailwind $(TAILWIND_VERSION) ($(TAILWIND_ASSET))"
	curl -fsSL -o $@.tmp https://github.com/tailwindlabs/tailwindcss/releases/download/$(TAILWIND_VERSION)/$(TAILWIND_ASSET)
	echo "$(TAILWIND_SHA256)  $@.tmp" | sha256sum -c -
	chmod +x $@.tmp && mv $@.tmp $@

icons:
	python3 tools/mkicons.py

# `make deps`: name what is missing before nasm or ld do it cryptically.
#   Debian/Ubuntu: apt install nasm binutils libsodium-dev python3 brotli libvips-tools
#   RHEL/Alma/Rocky: dnf install epel-release && dnf install nasm binutils libsodium-devel python3 brotli vips-tools
#   Alpine: apk add nasm binutils libsodium-dev python3 brotli vips-tools
deps:
	@ok=1; \
	command -v $(NASM) >/dev/null || { echo "missing: nasm"; ok=0; }; \
	command -v $(LD) >/dev/null || { echo "missing: ld (binutils)"; ok=0; }; \
	command -v python3 >/dev/null || { echo "missing: python3"; ok=0; }; \
	command -v brotli >/dev/null || echo "optional: brotli (set BLOGD_NO_BROTLI=1 to build without .br siblings)"; \
	command -v curl >/dev/null || { echo "missing: curl (fetches tools/tailwindcss; tests)"; ok=0; }; \
	sh tools/imgconv --check 2>/dev/null || echo "optional: an image converter for uploads (libvips-tools, ImageMagick, or python3 + Pillow)"; \
	test -x tools/tailwindcss || echo "tools/tailwindcss absent: make fetches and verifies it"; \
	$(NASM) -f elf64 $(NASM_PROBE) -o build/probe.o >/dev/null 2>&1 || { echo "nasm cannot assemble elf64"; ok=0; }; \
	if ! $(LD) -o /dev/null -lsodium --entry=0 -shared >/dev/null 2>&1; then \
	  echo "missing: libsodium development files (libsodium-dev / libsodium-devel from EPEL / libsodium-dev)"; ok=0; fi; \
	test "$$ok" = 1 && echo "deps: ok ($$($(NASM) -v))"

build:
	mkdir -p build

build/%.o: src/%.asm src/sys.inc src/conn.inc src/store.inc | build
	$(NASM) $(NASMFLAGS) $< -o $@

build/blogd: $(OBJ)
	$(LD) $(LDFLAGS) -o $@ $(OBJ) $(LDLIBS)

run: all
	./build/blogd

# `make test`: the theme contrast floor, then the pytest suite over real
# HTTP (tests/py: protocol, content, admin, markdown, media, the store
# CLI, crash recovery, lifecycle, the access log, and the fuzz corpus
# through the harnesses). tests/pytest.sh finds or creates a pytest.
test: all harness
	python3 tools/contrast.py
	./tests/pytest.sh

# ---- fuzz harnesses: the parsers linked into C drivers (tests/fuzz/) ----
# build/fuzz_http and build/fuzz_md link every server object except main.o,
# net.o and crypto.o; stubs.asm stands in for those. conn.h is the C view
# of the layout constants in conn.inc / store.inc.
CC ?= cc
FUZZ_OBJ := $(filter-out build/main.o build/net.o build/crypto.o,$(OBJ))
HARNESS_CFLAGS := -O1 -g -Wall -Wextra -no-pie -fno-pie -Ibuild -z noexecstack

build/conn.h: src/conn.inc src/store.inc | build
	sed -n 's/^%define \([A-Z_0-9]*\) *\([^;]*[^; ]\) *\(;.*\)\{0,1\}$$/#define \1 (\2)/p' $^ > $@

build/fuzz_stubs.o: tests/fuzz/stubs.asm src/sys.inc | build
	$(NASM) $(NASMFLAGS) $< -o $@

build/fuzz_http: tests/fuzz/harness.c build/conn.h build/fuzz_stubs.o $(FUZZ_OBJ)
	$(CC) $(HARNESS_CFLAGS) -o $@ $< build/fuzz_stubs.o $(FUZZ_OBJ)

build/fuzz_md: tests/fuzz/harness.c build/conn.h build/fuzz_stubs.o $(FUZZ_OBJ)
	$(CC) $(HARNESS_CFLAGS) -DFUZZ_MD -o $@ $< build/fuzz_stubs.o $(FUZZ_OBJ)

harness: build/fuzz_http build/fuzz_md

# `make fuzz`: the seed corpus (and any saved crashes) through the
# harnesses, then the black-box mutation run against a live server.
# `make afl MODE=http|md` runs AFL++ (FRIDA mode) over a harness.
fuzz: all harness
	./tests/fuzz/replay.sh
	./tests/fuzz/blackbox.sh

MODE ?= http
afl: all harness
	./tests/fuzz/afl.sh $(MODE)

load: all
	python3 tools/loadtest.py $(LOAD_ARGS)

# `make loadserver` on one machine, `make load LOAD_ARGS="--url http://<ip>:8090"` on another
loadserver: all
	python3 tools/loadtest.py --serve $(LOAD_ARGS)

image:
	docker build -t blogd .

clean:
	rm -rf build static/main.css static/main.css.gz static/main.css.br static/*-main.css static/*-main.css.gz static/*-main.css.br

.PHONY: all css icons deps run test harness fuzz afl load loadserver image clean
