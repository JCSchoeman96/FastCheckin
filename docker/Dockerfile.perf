FROM elixir:1.17.3-otp-27 AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git ca-certificates nodejs npm && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY priv priv
COPY assets assets

RUN npm install --prefix assets
RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM debian:bookworm-slim AS runner

RUN apt-get update && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates bash && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
ENV HOME=/app

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/fastcheck /app
COPY docker/app-perf-entrypoint.sh /app/bin/app-perf-entrypoint

RUN chmod +x /app/bin/app-perf-entrypoint

ENTRYPOINT ["/app/bin/app-perf-entrypoint"]
