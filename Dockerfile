# Build Docker. ONE image, TWO entrypoints: /bin/particle-worlds (the game
# server, which owns the per-turn decision layer) and
# /bin/particle-worlds-player (the thin seat registrar every policy runs). The
# whole policy set is env-switched inside this same image (PLAYER_PROMPT vs
# PLAYER_SCRIPTED), which is what keeps a champion and a scripted filler
# byte-identical apart from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/particle-worlds
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="src/particle_worlds.nim"
RUN nim $NimCommand \
  $NimFlags \
  --nimcache:/tmp/particle-worlds-nimcache \
  --out:particle-worlds \
  $NimMain && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/particle-worlds-player-nimcache \
  --out:particle-worlds-player \
  src/particle_worlds_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/particle-worlds
COPY --from=build /workspace/particle-worlds/particle-worlds /bin/particle-worlds
COPY --from=build /workspace/particle-worlds/particle-worlds-player /bin/particle-worlds-player
COPY --from=build /workspace/particle-worlds/*.json ./
COPY --from=build /workspace/particle-worlds/data ./data
COPY --from=build /workspace/particle-worlds/client ./client

CMD ["/bin/particle-worlds"]
