#!/bin/sh


bundle config --local clean true
bundle config --local path vendor/bundle
bundle config --local without vscode
bundle install

rm lib/memcache/native_server.o

export MEMCACHE_TEST_USER=postgres
export TEST_OPTS="--verbose --no-show-detail-immediately"

bundle exec rake test

