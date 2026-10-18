# MVP Spec: FUTO Voice Transcription Proof of Concept

## Goal
Prove that a FUTO speech-recognition model can transcribe a user-provided audio recording on macOS, locally.

## Requirements

1. **Platform:** macOS, command-line only. No GUI.
2. **Input:** Accept a local audio file path as a command-line argument.
3. **Model:** Use a speech-recognition model from the FUTO Voice Input Models repository.
4. **Inference:** Use a compatible local inference engine, preferably `whisper.cpp`.
5. **Output:** Print the transcription to standard output.
6. **Privacy:** Audio must be processed locally. No cloud transcription services.
7. **Dependencies:** Provide a simple setup script or clear instructions to build and run the tool on macOS.
8. **Errors:** Report clear errors for missing files, missing models, unsupported audio and transcription failures.

## Acceptance Criteria

- The tool builds and runs on macOS.
- It successfully loads a FUTO model.
- Given a valid audio recording, it prints the recognized text.
- Transcription works without an internet connection after setup and model installation.

## Out of Scope

GUI, microphone recording, streaming transcription, text editing, history, model selection UI, and distribution packaging.

## First Deliverable

A working command-line proof of concept that transcribes one supplied audio recording using a FUTO model locally.