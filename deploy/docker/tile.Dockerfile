# The tile emulator: the real firmware built for Linux (build context: the repository root).
FROM python:3.12-slim-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends g++ && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir platformio==6.2.0
COPY tile_firmware/ /fw/
RUN cd /fw && pio run -e native

FROM debian:bookworm-slim
COPY --from=build /fw/.pio/build/native/program /usr/local/bin/tile
EXPOSE 8090
ENTRYPOINT ["tile", "--no-term"]
