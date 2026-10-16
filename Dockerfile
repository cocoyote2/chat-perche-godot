# Dedicated server for Chat Perché Parkour: headless Godot running the project
# from source with `-- --server`. Players connect on UDP 7777.
FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
	&& wget -q https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip -O /tmp/godot.zip \
	&& unzip -q /tmp/godot.zip -d /tmp \
	&& mv /tmp/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
	&& rm /tmp/godot.zip \
	&& apt-get purge -y wget unzip \
	&& apt-get autoremove -y \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /game
COPY . .
RUN godot --headless --path . --import

EXPOSE 7777/udp
CMD ["godot", "--headless", "--path", "/game", "res://scenes/main.tscn", "--", "--server"]
