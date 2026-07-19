#!/bin/zsh
set -euo pipefail

model_dir="$HOME/Library/Application Support/MeetingCopilot/Models"
model_path="$model_dir/ggml-large-v3-turbo.bin"
model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required: https://brew.sh"
    exit 1
fi

if ! command -v whisper-server >/dev/null 2>&1; then
    brew install whisper-cpp
fi

mkdir -p "$model_dir"
curl -L --fail --continue-at - --output "$model_path" "$model_url"

echo "Local Whisper is ready:"
echo "$model_path"
