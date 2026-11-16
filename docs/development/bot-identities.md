# Bot identities

This document proposes a second dimension of the sandbox system of
[`agent-sandbox.md`](agent-sandbox.md). Sandbox modules say what a checkout
can reach: which tools, domains, sockets and paths. Bot identities say as
whom the checkout acts at each service it reaches. Nothing in this document
is built, and the open questions at the end decide how much code it needs.

A **bot identity** is one that the coding agents of a person assume, and a
broker manages it. The agent proves nothing about itself. The person
assigns an identity to a checkout, and the broker mints short-lived
credentials for it. The agent never holds a credential of the person.

## Problem

Today a checkout that reaches a service reaches it as the person. The
GitHub module, for example, gives the sandboxed `gh` the token of the
person through a trusted executable. That credential can do everything the
person can do at that service, and the modules offer no way to say less. A
checkout should act at each service with the narrowest identity that its
work needs, and the person should be able to choose that identity per
checkout.

## Design

A checkout has two kinds of setting that concern a service:

| Dimension | Question | Where it lives | Example |
|---|---|---|---|
| Module | Can this checkout reach the service? | The chosen modules of the sidecar | `google` |
| Bot identity | As whom does it act there? | A map of the sidecar, from a service to an identity | `google = "software-dev-apply"` |

The two settings are independent. A checkout without the module has no
access, whatever its map says. A checkout with the module and no entry in
the map acts as the default identity that the service declares, which is
the least powerful one, for example a reader. Both settings are edits that
the person makes outside the sandbox, and the sidecar is write-guarded, so
the agent cannot change either.

The pieces:

- **The broker** is a user service that runs outside every sandbox. It
  holds what the person has (the Application Default Credentials for
  Google, an app key for GitHub) and listens on one unix socket for each
  declared bot identity, under `$XDG_STATE_HOME/agent-sandbox/trusted/`,
  started like a trusted executable by a systemd socket unit. It mints a
  short-lived credential for the identity of the socket and applies it to
  the requests that arrive there.
- **Providers** are the adapters of the broker, one for each service. A
  provider knows how to mint a credential for an identity of its service
  and how to apply it. Google is the first provider, and GitHub is the
  second.
- **Declarations** are home-manager options that name each bot identity:
  its service, its name, and the provider settings, for example the service
  account of a Google identity.
- **The composer** reads the map of the sidecar. For each service it adds
  the socket of the chosen identity to the `allowUnixSockets` of the
  checkout, and no other identity socket of that service, so the Landlock
  narrowing of the sandbox keeps the checkout away from the other
  identities. A new verb of `agent-sandbox`, for example `agent-sandbox bot
  google NAME`, would write an entry and sync the checkout.

The broker makes no decision at run time. What an identity can do is
decided by the service, through the permissions of the identity, which the
person defines in code.

## Providers

### Google Cloud

A bot identity on Google Cloud is a service account that the person can
impersonate. The Application Default Credentials (ADC) of the person, which
`gcloud` and the client libraries find on the machine, call
`generateAccessToken` for the service account, which needs the Service
Account Token Creator role on it. The call returns a token that lasts up to
an hour, and the broker mints a new one when the old one nears its end.

The infrastructure code defines the service accounts and their IAM
bindings, and the declaration in home-manager names them. A binding can
restrict a service account to a folder, a project or a resource tag. The
organization `hodapp.cloud` has four top-level folders:

```
organization
├── prod          one folder for each partition of the infrastructure,
│                 with more folders and projects below it; shared by
│                 several tenants where that is practical
├── software-dev  copies of prod that deploy only the partitions under
│                 development
├── sandbox       shared copies of dependencies for all developers, empty
│                 until a dependency needs one
└── infra-dev     N separate runs of the whole of software-dev and sandbox,
                  to test changes to the automation itself
```

Examples of Google identities are a reader with viewer roles at the
organization, one that applies infrastructure in `software-dev`, and one
that changes IAM policies in `infra-dev`.

Impersonated tokens appear in the audit log as the service account. From
the documentation of the audit log, the person who made the call appears in
the delegation information of the entry (`serviceAccountDelegationInfo`).
The field names were not checked against the current reference.

The `google` module supplies the commands (`tofu`, `gcloud`) and the
environment that points the Google clients at the broker and gives them the
placeholder token `proxy-replace`. The broker replaces the `Authorization`
header of every request with the token that it minted.

### GitHub

A bot identity on GitHub is a GitHub App. The broker signs a short assertion
with the key of the app and trades it for an installation token, which
expires after an hour and reaches only the repositories where the app is
installed. The `github` module gives the sandboxed `gh` that token instead
of the token of the person. The mechanism is the one that
`githubKeyring` uses today, with a different source for the token. The
details of this provider are not designed yet.

### Other services

AWS and Azure would be providers of the same shape: a role or a managed
identity that the person can assume, and a short-lived credential for it.

## Trust in the machine

The broker holds the credentials of the person, so a service trusts the
whole machine as that person. That trust starts when the credential is
created, and a service can require a touch of a hardware security key for
that sign-in and for each renewal. Google offers this, for example. Ending
a session in the service, by signing the account out and revoking its
tokens, ends the trust in a machine at once.

## Filtering requests

A later version can check each request before it sends the request. For
Google that means the method of the API, read from the discovery document
of the API, and the project that the request names, resolved to its
ancestors by following the `parent` field of a project or folder. The
permissions of the identity limit what a service accepts either way, and the
filter adds a check that does not depend on the permissions being right.

## What the broker does not cover

- A checkout is as strong as the permissions of its identity. The code that
  defines the identities is the place to review them.
- The credentials of the person stay on the machine outside the sandbox. A
  process with access to them can mint tokens without the broker.
- A token lasts up to an hour. A token that the broker applies to a request
  never reaches the sandbox, so the sandbox cannot keep one.
- Calls that bypass the broker fail, because the sandbox holds no credential.

## Open questions

- **How clients reach the broker.** For Google, the broker has to receive
  each request to replace its token, so a client has to send its requests
  to a local address in plain HTTP, and the broker re-issues them to Google
  over TLS. The documentation shows three mechanisms. `gcloud` has an
  `api_endpoint_overrides/<service>` property for each service, with a
  matching environment variable
  (`CLOUDSDK_API_ENDPOINT_OVERRIDES_<SERVICE>`). The Google provider for
  Terraform and OpenTofu has a `*_custom_endpoint` setting for each product,
  and a `universe_domain` setting since version 5.18.0. The Python client
  libraries read the universe domain from `GOOGLE_CLOUD_UNIVERSE_DOMAIN`.
  The module would set the overrides for the services that a configuration
  uses, and a service without an override sends its request to Google
  without a credential and fails. The broker refuses a request that carries
  any bearer value other than the placeholder, so a client that found a real
  credential is noticed. A universe domain setting may make a client refuse
  credentials from the default universe. The fallback is a proxy that
  terminates TLS with a certificate authority that the sandbox trusts, which
  is more code and a larger risk. Which libraries respect these settings for
  every call has not been tested.
- **From a unix socket to a local address.** The clients need an HTTP
  address, the sandbox offers a unix socket, and the native sandbox of
  Codex runs commands in a separate network namespace, so a listener on the
  host loopback is out of reach. A small relay inside the sandbox, started
  by the module, would listen on a loopback port and copy the bytes to the
  socket. How the module starts it, and for how long, has not been decided.
- **The map in the sidecar.** The composer and the sidecar format need a
  place for a map from a service to an identity. Whether this fits the
  current `binding.json` has not been checked.
- **The credential code.** The broker needs a token cache, the reading of
  ADC files, and the impersonation call. The proxy of
  `nix-cache-polyfill` (`clhodapp/nix-cache-polyfill`) is building the same
  pieces for Nix binary caches. Whether the broker depends on a library of
  that repository or keeps a copy has not been decided.
