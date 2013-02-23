NPM=npm
NODE=node

COFFEE=coffee

TARGETS = $(patsubst src/%.coffee,lib/%.js,$(shell find src -name \*.coffee))

all: node_modules $(TARGETS)

lib/%.js: src/%.coffee
	@mkdir -p $(shell dirname $@)
	$(COFFEE) -c -s < "$<" > $@

node_modules: package.json
	$(NPM) install

clean:
	rm -rf $(TARGETS)

run: all
	$(NODE) lib/main

watch:
	nodemon -w src --exec ./build_and_run lib/main.js

.PHONY: all clean run watch
