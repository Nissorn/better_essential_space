# Better Essential Space

A native macOS client for Nothing's Essential Space: it logs in with a Nothing Account and displays Essential Space content. This glossary fixes the vocabulary shared between the RE notes, the issue tracker, and the app.

## Essential Space (Nothing's side)

**Essential Space**:
Nothing's capture-and-recall service on Nothing phones: what the Essential Key captures is stored on the phone and synced to Nothing's cloud.
_Avoid_: notes app, ES

**Essential Key**:
The dedicated hardware button on Nothing phones that triggers a capture.
_Avoid_: capture button, trigger

**Record**:
A voice capture: its audio plus its transcript.
_Avoid_: voice note, recording, memo

**Transcript**:
The text of what was said in a Record.
_Avoid_: transcription, subtitle

**Memory**:
An entry in Nothing's AI memory feature, served by the memories API on the current backend. Not where Records live; the account's memory list can be empty while its Records exist.
_Avoid_: memory item, note

**Card**:
The content item of the Essential Space storage backend that serves Records: an envelope whose payload carries the title, summary, and resources (audio file reference plus Transcript). Records are Cards.
_Avoid_: item, entry

**Collection**:
A user-named group of Cards on the legacy storage backend.

## Account & login

**Nothing Account**:
The user account at Nothing's account service, identified by its uuid.
_Avoid_: user (ambiguous), Nothing ID, bare "account"

**Authflow**:
The interactive login flow of the account service: email and password, then a one-time code.
_Avoid_: login flow, OAuth (that is the token layer underneath)

**Access Token**:
The bearer credential for Nothing account and Essential Space APIs, obtained at login or by refresh.
_Avoid_: JWT, bare "token", nothingToken

**Refresh Token**:
The long-lived credential used to obtain a new Access Token without logging in again.

**Device Report**:
A client's self-description registering a device with the account service; yields a Device ID.
_Avoid_: device registration, activation

**Device ID**:
The server-assigned identity of a registered device, recorded inside the Access Token.

**Device Secret**:
A secret bound to a registered device, issued at token exchange; used for SSO exchange.
