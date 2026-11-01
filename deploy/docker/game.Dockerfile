# The game (Godot), as a screen PC runs it (build context: the repository root).
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip libfontconfig1 libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 \
        libxext6 libxrender1 libxkbcommon0 libgl1 libegl1 libgl1-mesa-dri libvulkan1 mesa-vulkan-drivers \
        libasound2 libpulse0 libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*
ARG GODOT=4.7.2
RUN curl -fsSL -o /tmp/godot.zip \
        https://github.com/godotengine/godot/releases/download/${GODOT}-stable/Godot_v${GODOT}-stable_linux.x86_64.zip \
    && unzip /tmp/godot.zip -d /tmp && mv /tmp/Godot_v${GODOT}-stable_linux.x86_64 /usr/local/bin/godot \
    && rm /tmp/godot.zip
COPY godot/ /game/
RUN godot --headless --path /game --import 2>&1 | tail -3
ENTRYPOINT ["godot", "--path", "/game"]
