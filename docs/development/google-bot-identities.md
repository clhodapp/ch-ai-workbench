# Google bot identities for sandboxed agents

This document proposes how a sandboxed coding agent uses Google Cloud
without holding a credential of the person. Nothing in it is built, and
the open questions at the end decide how much code it needs.

A **bot identity** is one that the coding agents of a person assume, and
a broker manages it. The agent proves nothing about itself. The person
assigns an identity to a checkout, and the broker mints short-lived
credentials for it. On Google Cloud a bot identity is a service account that
the person can impersonate. On GitHub it would be a GitHub App, whose
installation tokens expire after an hour and reach only the repositories
where the app is installed.

## Problem

A person has Application Default Credentials (ADC), the Google credential
that `gcloud` and the client libraries find on the machine. Those
credentials can do everything the person can do, including changes at the
root of the organization. An agent should be able to plan and apply
infrastructure where its repository works, and read the rest, without ever
holding that credential.

## Design

Access has two dimensions. One is what is accessed: the folders, projects
and resource tags of the organization. The other is the identity that does
the accessing. The infrastructure code defines both: each bot identity is a
service account, and its IAM bindings say what it can touch. The
`agent-sandbox` configuration of a checkout adds a third thing, which is
the identity that the checkout uses.

The pieces follow [`agent-sandbox.md`](agent-sandbox.md):

- **The broker** is a user service, started like a trusted executable by
  a systemd socket unit, that runs outside every sandbox with the ADC of
  the person. A home-manager option declares each bot identity by name and
  service account, and the broker listens on one unix socket for each,
  under `$XDG_STATE_HOME/agent-sandbox/trusted/`. It mints a short-lived
  token for the service account of the socket and forwards the requests
  that arrive there to Google with that token.
- **The `google` sandbox module** gives a checkout the ability to reach a
  broker socket. It supplies the commands that need it (`tofu`, `gcloud`),
  the environment that points the Google clients at the broker and gives
  them the placeholder token `proxy-replace`, and the relay described
  under the open questions. A checkout without the module has no access to
  Google Cloud.
- **The bot identity of the checkout** is a setting of the sidecar
  (`.agent-sandbox/binding.json`), beside the chosen modules, and it
  exists only when the checkout chose the `google` module. It names one of
  the declared identities. A checkout with the module and no setting gets
  the reader. The composer takes the setting as an input: it adds the
  socket of that identity to the module's `allowUnixSockets` and no other
  broker socket, so the Landlock narrowing of the sandbox keeps the
  checkout away from the sockets of other identities.

Giving a checkout a stronger identity is an edit that the person makes
outside the sandbox. The sidecar is write-guarded, so the agent cannot make
it. A new verb of `agent-sandbox`, for example `agent-sandbox bot google
NAME`, would write the setting and sync the checkout. The broker makes no
decision at run time. Google enforces what the service account can do.

### The resource hierarchy

The resource hierarchy of Google Cloud is a tree: an organization contains
folders, and folders contain projects and other folders. The organization
`hodapp.cloud` has four top-level folders.

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

### Identities

A bot identity is a service account in the infrastructure code, with a name
that says its purpose. Examples are a reader with viewer roles at the
organization, an identity that applies infrastructure in `software-dev`,
and one that changes IAM policies in `infra-dev`. The code binds the roles
of each identity on the folders and projects that it may touch, and it can
restrict a binding with a condition on resource tags. The code also gives
the person the Service Account Token Creator role on each identity that a
checkout may use, which lets the ADC of the person mint its tokens.

Impersonated tokens appear in the audit log as the service account. From
the documentation of the audit log, the person who made the call appears in
the delegation information of the entry (`serviceAccountDelegationInfo`).
The field names were not checked against the current reference.

### Trust in the machine

The broker holds the credential of the person, so Google trusts the whole
machine as that person. That trust starts when the credential is created,
and Google can require a touch of a hardware security key for that sign-in
and for each renewal. Signing the account out in Google and revoking its
tokens ends the trust in a machine at once.

### Filtering requests

A later version can check each request before it sends the request: the
method of the API, read from the discovery document of the API, and the
project that the request names, resolved to its ancestors by following the
`parent` field of a project or folder. The service account limits what
Google accepts either way, and the filter adds a check that does not depend
on the bindings being right.

## What the broker does not cover

- A checkout is as strong as the bindings of its identity. The code that
  defines the identities is the place to review them.
- The ADC of the person stays on the machine outside the sandbox. A process
  with access to it can mint tokens without the broker.
- Impersonated tokens last up to an hour. A token that the broker sends to
  Google never reaches the sandbox, so the sandbox cannot keep one.
- Calls that bypass the broker fail, because the sandbox holds no credential.

## Open questions

- **How clients reach the broker.** The broker has to receive each request
  to replace its token, so a client has to send its requests to a local
  address in plain HTTP, and the broker re-issues them to Google over TLS.
  The documentation shows three mechanisms. `gcloud` has an
  `api_endpoint_overrides/<service>` property for each service, with a
  matching environment variable
  (`CLOUDSDK_API_ENDPOINT_OVERRIDES_<SERVICE>`). The Google provider for
  Terraform and OpenTofu has a `*_custom_endpoint` setting for each product,
  and a `universe_domain` setting since version 5.18.0. The Python client
  libraries read the universe domain from `GOOGLE_CLOUD_UNIVERSE_DOMAIN`.
  The module would set the overrides for the services that a configuration
  uses, and a service without an override sends its request to Google
  without a credential and fails. The broker replaces the `Authorization`
  header of every request with a token that it minted, and it refuses a
  request that carries any other bearer value, so a client that found a real
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
- **The credential code.** The broker needs a token cache, the reading of
  ADC files, and the impersonation call. The proxy of
  `nix-cache-polyfill` (`clhodapp/nix-cache-polyfill`) is building the same
  pieces for Nix binary caches. Whether the broker depends on a library of
  that repository or keeps a copy has not been decided.
- **The setting in the sidecar.** The composer and the sidecar format
  need a place for a setting that belongs to a module and exists only when
  the checkout chose it. Whether this fits the current `binding.json` has
  not been checked.
