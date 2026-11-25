ARG RUBY_VERSION
FROM ruby:${RUBY_VERSION}-bookworm
ARG BUNDLER_VERSION
ENV BUNDLER_VERSION=${BUNDLER_VERSION}
RUN gem install --no-document bundler -v "$BUNDLER_VERSION" && gem install --no-document webrick -v 1.9.2
WORKDIR /work
