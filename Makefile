# Convenience targets on top of rebar3. See AGENTS.md for the check list.

.PHONY: all compile test fmt fmt-check lint static check clean

all: compile

compile:
	rebar3 compile

test:
	rebar3 ct

fmt:
	rebar3 fmt
	clang-format -i c_src/*.c c_src/*.h

fmt-check:
	rebar3 fmt --check
	clang-format --dry-run -Werror c_src/*.c c_src/*.h
	shellcheck scripts/*.sh
	scripts/test-fetch.sh

lint:
	rebar3 lint

static: fmt-check lint
	rebar3 xref
	rebar3 dialyzer

check: static test

clean:
	rebar3 clean
	rm -rf _build/default/lib/erlang_wasmtime doc
