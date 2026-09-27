.PHONY: build selftest doctor check verify clean

build:
	swift build

selftest:
	swift run photoarchive-selftest

doctor:
	swift run photoarchive doctor

check:
	bash scripts/check-public-tree.sh

verify: check build selftest doctor

clean:
	swift package clean
