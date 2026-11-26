ARG RUBY_VERSION
FROM ruby:${RUBY_VERSION}-bookworm
# renovate: datasource=rubygems depName=bundler versioning=ruby
ARG BUNDLER_VERSION=2.7.2
# renovate: datasource=rubygems depName=webrick versioning=ruby
ARG WEBRICK_VERSION=1.9.2
ENV BUNDLER_VERSION=${BUNDLER_VERSION}
RUN gem install --no-document bundler -v "$BUNDLER_VERSION" && gem install --no-document webrick -v "$WEBRICK_VERSION"
WORKDIR /work
