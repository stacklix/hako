# Remote Control Design

## Goal

Doppel can run a foreground Android HTTP service so a remote browser can log in and control the app over HTTP.

## Architecture

Android owns the remote control runtime. Flutter only edits configuration and displays status. A foreground service starts a small HTTP server on the configured port, serves a login page plus control page, and exposes authenticated JSON endpoints for snapshot, SMS, call, and config actions.

## Configuration

Remote settings live under `config_json.remoteControl`:

- `enabled`: whether the foreground service should run.
- `port`: HTTP listen port, default `18080`.
- `password`: management password required by `/login`.

The app must not log passwords, session cookies, or authorization headers.

## HTTP Routes

- `GET /health`: public service status.
- `GET /`: login page or control page depending on session cookie.
- `POST /login`: password login, creates an in-memory session cookie.
- `POST /logout`: clears the session cookie.
- `GET /api/snapshot`: authenticated snapshot.
- `POST /api/sms/send`: authenticated SMS send.
- `POST /api/call/start`: authenticated call start.
- `POST /api/config`: authenticated config merge.

## Foreground Service

When remote control is enabled and a password is present, `RemoteControlService` runs as an Android foreground service with a persistent notification. Disabling the setting stops the service and closes the port.

## Web Console

The web page is returned by the native HTTP service as static HTML/CSS/JS. It shows current snapshot, recent logs, SMS and call forms, and a raw JSON config editor for controlled updates.

## Validation

Run:

```bash
/Users/liqiao/sdk/flutter/bin/flutter analyze
/Users/liqiao/sdk/flutter/bin/flutter test test/widget_test.dart
/Users/liqiao/sdk/flutter/bin/flutter build apk --debug
```
