# Bot identities

This document proposes a second dimension of the sandbox system of
[`agent-sandbox.md`](agent-sandbox.md). Sandbox modules say what a checkout
can use: which tools, domains, sockets and paths. A bot identity says who
the agent acts as while it uses them. Nothing in this document is built.

A **bot identity** is one that the coding agents of a person assume, and a
proxy manages it. It is one entity with a name, such as `software-dev`,
and it can have a Google account, a GitHub account, and an account of any
other kind that the person declares. An account is a service account or an
app that the person grants to the bot identity, or the account of the person. The agent proves nothing about
itself. The person assigns a bot identity to a checkout, the agents that run
in the checkout act as that identity, and the proxy mints short-lived
credentials for its accounts. The agent never holds a credential of the
person.

## Problem

Today an agent uses a service with the credentials of the person. The
GitHub module, for example, gives the sandboxed `gh` the token of the
person through a trusted executable. That credential can do everything the
person can do, and the sandbox cannot restrict it to a part of that. An
agent should act as the narrowest identity that its work needs, and the
person should be able to choose that identity for each checkout.

## Design

A checkout has two settings that concern the services it uses:

| Dimension | Question | Where it lives | Example |
|---|---|---|---|
| Modules | What can this checkout use? | The chosen modules in the binding file | `google`, `github` |
| Bot identity | Who does the agent act as? | One setting in the binding file | `bot = "software-dev"` |

The binding file is `.agent-sandbox/binding.json` in each enrolled
checkout. It records the enrollment: the chosen modules, their deadlines,
the declined modules and the last settings applied.

The two settings answer different questions, and an agent needs both to
use Google. The `google` module gives the agent access to Google, and the
bot identity supplies the Google account that the agent acts as. That
account is a service account that the person can impersonate, or the
account of the person. An agent in a checkout without the module has no
access to Google, whatever its bot identity holds, and an agent whose bot
identity has no Google account has no access to Google even with the
module. A checkout with no bot identity setting gives its agents the default bot
identity, which the person declares and which should be the least powerful
one. Both settings are edits that the person makes outside the sandbox, and
the binding file is write-guarded, so the agent cannot change either.

The pieces:

- **The declaration** is a home-manager option. It names each bot identity
  and its accounts, for example a Google service account and a GitHub App.
- **The proxy** is a user service that runs outside every sandbox. It
  holds what the person has (the Application Default Credentials for
  Google, an app key for GitHub) and listens on one unix socket for each
  account of each bot identity, under
  `$XDG_STATE_HOME/agent-sandbox/trusted/`, started like a trusted
  executable by a systemd socket unit. It mints a short-lived credential
  for the account of the socket and applies it to the requests that arrive
  there.
- **Providers** are the adapters of the proxy. Google is the first and
  GitHub is the second. A provider knows how to mint a credential for its
  kind of account and how to apply it.
- **The composer** (`compose.py`) reads the bot identity setting of the
  binding file. For each chosen module that has a provider, it adds the socket
  of the account of that identity to the `allowUnixSockets` of the
  checkout, and no other account socket, so the Landlock narrowing of the
  sandbox keeps the checkout away from the accounts of other bot
  identities. A new verb of `agent-sandbox`, for example `agent-sandbox bot
  NAME`, would write the setting and sync the checkout.

What a bot identity can do is decided by the service that owns the account,
through the permissions of the account, which the person defines in code.

The agent never receives a token, whether of the person or of a bot
identity. A token goes from the proxy to the service and stays out of the
environment, the files and the responses that the sandbox sees. Two
consequences follow. The proxy refuses every request to an endpoint that
issues credentials (for Google `iamcredentials.googleapis.com`,
`sts.googleapis.com` and the token endpoint of OAuth), whatever the
permissions of the bot identity say, because a successful call would return
a token. The proxy also keeps tokens out of its logs.

A client finds the proxy at a local address in plain HTTP, and the proxy
sends the request on to the service over TLS. Each provider section below
names the setting that points its clients at the proxy. The sandbox offers
a unix socket, the clients need an HTTP address, and the native sandbox of
Codex runs commands in a separate network namespace, so a listener on the
host loopback cannot be used. A small relay inside the sandbox, started by
the module, listens on a loopback port and copies the bytes to the socket.
The wrappers that the module puts on `PATH` for its commands (`tofu`,
`gcloud`, `gh`) start the relay for the length of the command and stop it
afterwards, and the module requests `allowLocalBinding`, which
`agent-sandbox` already offers to a module that needs a local server. The
proxy refuses a request that carries any credential other than the
placeholder, so a client that found a real credential is noticed. A client
without an endpoint setting sends its request straight to the service
without a credential, and the request fails.

## A bot identity that is the person

A bot identity can use the accounts of the person. The proxy then applies
the token of the person to the requests of the sandbox, with no
impersonation and no narrowing. The agent acts fully as the person and
never sees the credential. The person declares such a bot identity like any
other, and assigns it to a checkout with the same edit of the binding file. It
is never the default bot identity.

Two rules matter most for this bot identity.

- **Credential-creating calls.** The proxy refuses the methods that create
  a credential as well as the endpoints that issue tokens, for example the
  creation of a service account key in the IAM API of Google, because a key
  is a long-lived credential that the agent would then hold.
- **Audit.** A service records requests from this bot identity as the
  person. The log of the proxy is the only record that tells them apart,
  so it names the checkout and the bot identity on every request.

## Keeping real credentials out of reach

A tool that asks for a token must get the placeholder `proxy-replace` and
nothing else, and no file or command that the sandbox can read may hold a
real one. Each service module therefore does three things.

- **It sets the placeholder where the tool looks first.** `GH_TOKEN` for
  `gh`, and for Google the variables of the Google clients (for `gcloud`,
  `CLOUDSDK_AUTH_ACCESS_TOKEN`).
- **It provides a configuration directory with the placeholder in it.** The
  module sets `GH_CONFIG_DIR` and `CLOUDSDK_CONFIG` to directories in the
  checkout that hold only the placeholder. An agent that unsets the
  environment variable still gets the placeholder from `gh auth token` and
  `gcloud auth print-access-token`, and not the credentials of the person.
- **It grants no path to a real credential.** The `githubKeyring` socket,
  which returns the token of the person, is not granted. The composer adds
  the sockets of the bot identity of the checkout and no others.

The sandbox also has to stop reading the credential stores of the person.
The tools keep them at `~/.config/gcloud` (the file
`application_default_credentials.json`, and `credentials.db` of `gcloud`),
`~/.config/gh/hosts.yml`, and `~/.aws` (the file `credentials` and the
caches of the SSO login and the CLI). A check on 2026-11-16
found `~/.config/gcloud/credentials.db` readable from inside an enrolled
sandbox, so the baseline of `agent-sandbox` does not cover these paths
today.

Closing this gap changes what existing checkouts can read, so it is an
opt-in. A home-manager option of `agent-sandbox` (for example
`denyCredentialStores`) makes the baseline deny reads of the paths above.
It is off by default at first, and each downstream configuration turns it
on when it is ready. A later release changes the default to on, after the
downstream configurations that use the sandbox have turned it on and
listed any path that a tool of those configurations needs. The same
staging applies to the other steps of this section: each is an option, and
the default changes only after the downstreams have moved.

The option has two forms, and a downstream configuration can use either.

- **A list of credential stores.** `denyCredentialStores` takes a list of
  paths, with the stores named above as the default content. The person adds
  the stores of other tools, such as `~/.ssh`, `~/.netrc`, `~/.docker`,
  `~/.kube` or the password files of a browser. A list names only the
  stores that someone thought of, so it closes the known gaps.
- **A list of the places that the agent may read.** A second option makes
  reads under `$HOME` and under the other places that tend to hold
  credentials (`/etc/ssh`, `/root`, the runtime directory of the user) deny
  by default, and allows the paths in a list. The list starts from the read
  paths that the chosen modules already declare, plus the checkout, and the
  person extends it. This closes the unknown gaps, and its cost is that each
  tool that reads a dotfile has to be named by a module or by the person.

The first form is the first step, since it changes little. The second is the
end state, and it moves in the same way: an option, off by default, turned
on by each downstream configuration before the default changes.

A test in the style of `github-keyring-vm` verifies the rule. A VM holds a
disposable real token in each place above and in the keyring. A sandboxed
checkout runs `gh auth token` (with and without `GH_TOKEN`, and with
`--hostname github.com`), `gcloud auth print-access-token`, `env`, and a
search of every readable file. The test passes only if the real tokens
appear in no output and no readable file.

A second test runs each client (`gcloud`, `tofu`, the Google client
libraries, `gh`, `git`, the AWS CLI and SDKs, `ssh`) in a sandbox whose only
network is the proxy. A client that ignores its endpoint setting for some
call has nowhere else to send it, so the call fails and the test shows
which client it was.

## Compatibility for downstream configurations

A downstream configuration that sets none of the new options must evaluate
and sandbox as it does before the change. The code has to keep four rules.

- **The new setting is optional.** `read_sidecar` in `files.py` reads the
  keys that it knows and ignores the rest, so a `binding.json` without a bot
  identity setting reads as it does today. `write_sidecar` writes only
  `modules`, `applied`, `expires` and `declined`, so it has to write the new
  setting too, or the next `add`, `drop` or `sync` erases it. The setting
  matters only to a checkout that chose a service module.
- **The `github` module keeps its behavior.** Today it hands the token of
  the person to `gh` through the keyring broker. The `github.localhost`
  behavior is a separate module, or an option of the module that is off
  by default.
- **Options are off by default** until the defaults change, and the change
  is announced in the release notes of the repository.
- **A new flake input needs no setting.** If the proxy shares code with
  another repository, a downstream locks that input through the normal
  convergence.

While an option is off, `agent-sandbox status` reports which closing steps
the configuration has not turned on. A running session keeps its sandbox
rules until it restarts, as it does for any other change.

## Providers

### Google Cloud

The Google account of a bot identity is a service account that the person
can impersonate, or the account of the person. The rest of this section
describes the service account. The Application Default Credentials (ADC) of the person,
which `gcloud` and the client libraries find on the machine, call
`generateAccessToken` for the service account, which needs the Service
Account Token Creator role on it. The call returns a token that lasts up to
an hour, and the proxy mints a new one when the old one nears its end.

The infrastructure code defines the service accounts and their IAM
bindings, and the declaration of the bot identity names them. A binding can
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

Examples of bot identities are a reader whose Google account has viewer
roles at the organization, one whose account applies infrastructure in
`software-dev`, and one whose account changes IAM policies in `infra-dev`.

Impersonated tokens appear in the audit log as the service account. From
the documentation of the audit log, the person who made the call appears in
the delegation information of the entry (`serviceAccountDelegationInfo`).
The field names were not checked against the current reference.

The `google` module supplies the commands (`tofu`, `gcloud`) and the
environment that points the Google clients at the proxy and gives them the
placeholder token `proxy-replace`. The proxy replaces the `Authorization`
header of every request with the token that it minted.

The Google clients take an endpoint in three ways. `gcloud` has an
`api_endpoint_overrides/<service>` property for each service, with a
matching environment variable (`CLOUDSDK_API_ENDPOINT_OVERRIDES_<SERVICE>`).
The Google provider for Terraform and OpenTofu has a `*_custom_endpoint`
setting for each product, and a `universe_domain` setting since version
5.18.0. The Python client libraries read the universe domain from
`GOOGLE_CLOUD_UNIVERSE_DOMAIN`. The module sets the overrides for the Google
services that a configuration uses. A universe domain setting may make a
client refuse credentials from the default universe. If a client cannot take
an endpoint, the fallback is a proxy that terminates TLS with a certificate
authority that the sandbox trusts, which is more code and a larger risk.

### GitHub

The GitHub account of a bot identity is a GitHub App. The proxy signs a
short assertion with the key of the app and trades it for an installation
token, which expires after an hour and reaches only the repositories where
the app is installed. The proxy applies that token to the GitHub requests
of the sandbox, so `gh` and `git` never receive it. The `githubKeyring`
mechanism of today hands the token of the person to `gh`, which does not
meet that rule.

The source of `gh` (`internal/ghinstance/host.go` in `cli/cli`, and
`pkg/auth/auth.go` in `cli/go-gh`) treats the host `github.localhost` as a
local development instance. For it, `gh` speaks plain HTTP: the web host
is `http://github.localhost/`, the REST API is `http://api.github.localhost/`
with no `/api/v3`, GraphQL is `http://api.github.localhost/graphql`, and
the token comes from `GH_TOKEN`. Any other unknown host name is classified
as GitHub Enterprise Server, which means HTTPS, `/api/v3` and
`GH_ENTERPRISE_TOKEN`, so the module would use `github.localhost`.

The `github` module would set `GH_HOST=github.localhost` and give `gh` the
placeholder `proxy-replace` as `GH_TOKEN`, as the `google` module does.
`git` over HTTP would reach the same host through a `url.<base>.insteadOf`
rewrite of `https://github.com/`, and a URL for `git` can carry any port.

A host name for `gh` cannot carry a port, so the relay would have to listen
on port 80. A test on 2026-11-19 in the Claude Code sandbox of this
workspace showed that `github.localhost`, `api.github.localhost` and
`uploads.github.localhost` resolve to `127.0.0.1`, and that binding port 80
fails with "Permission denied", while binding port 8080 works. The module
therefore starts with `git` on a high port. `gh` needs a sandbox in which
the relay may bind a low port, for example a user namespace in which the
process holds that capability, or the host setting
`net.ipv4.ip_unprivileged_port_start`, and the Codex native sandbox has to
be tested for this. The source shows `HostPrefix` and `RESTPrefix` agreeing
on `github.localhost` itself and disagreeing for a subdomain such as
`foo.github.localhost`, so the module uses the exact name.

### AWS

The AWS account of a bot identity is an IAM role that the person can
assume. The proxy calls `sts:AssumeRole` with the credentials of the person
and receives an access key, a secret key and a session token that last up
to the maximum session duration of the role, one hour by default. The proxy
can set the role session name to the bot identity and `SourceIdentity` to
the person, so that CloudTrail attributes each call.

AWS differs from Google and GitHub in how a request carries its credential.
The SDK signs each request with the secret key (Signature Version 4), so
the proxy cannot replace a header. The module gives the SDK a dummy access
key and secret key in environment variables. The SDK signs with them, and
the proxy discards that signature, signs the request again with the real
session credentials, and forwards it. The module points the SDK at the
proxy with `AWS_ENDPOINT_URL`, or with `AWS_ENDPOINT_URL_<SERVICE>` for one
service, which takes precedence ([service-specific
endpoints](https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html)).
The module must not use a provider that fetches credentials over HTTP, such
as the container credential provider
([`AWS_CONTAINER_CREDENTIALS_FULL_URI`](https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html)),
because it would hand real credentials to the SDK.

The refusal list covers the calls that issue credentials: `AssumeRole`,
`GetSessionToken` and `GetFederationToken` of STS, and the creation of an
access key in IAM. The credential stores to deny are all of `~/.aws`, which
includes the caches of the SSO login and of the CLI.

Signing again needs the whole request. Payloads that the SDK signs in
chunks while it streams an upload, and presigned URLs, are the cases that
the proxy has to handle separately, and the endpoint names differ for each
service and region. The test of the endpoint settings above shows which
SDKs ignore them.

### SSH

An SSH key can stay inside `ssh-agent`. The agent signs a challenge when a
client asks, and a client that talks to it through the socket in
`SSH_AUTH_SOCK` learns the signature and never the key. The proxy for SSH
is a filtering ssh-agent that runs outside the sandbox. It lists only the
keys that the bot identity has, signs only with them, and listens on the
socket that the module places in the sandbox. The account of a bot identity
is such a key, or an SSH certificate with a short validity that a
certificate authority signs, which matches the lifetimes of the other
providers. A bot identity that is the person offers the keys that the person
chooses from the agent of the person.

A signing socket lets the agent authenticate with the key to any host that
it can connect to. The network allowlist of the sandbox limits the hosts.
OpenSSH 10.6, the version installed on this machine, also binds a key to
destination hosts when it is added to an agent (`ssh-add -h
destination_constraint`) and gives a key a lifetime (`ssh-add -t life`).
The proxy for SSH keeps the constraints of the keys that it holds and signs
only for the hosts that they allow.

### Other providers

Azure would be a provider of the same shape as AWS and Google: a managed
identity that the person can assume, and a short-lived credential for it.

## Trust in the machine

The proxy holds the credentials of the person, so a service trusts the
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
permissions of the account limit what a service accepts either way, and the
filter adds a check that does not depend on the permissions being right.

## What the proxy does not cover

- An agent is as strong as the permissions of the accounts of its bot
  identity. The code that defines the accounts is where to review them.
- The credentials of the person stay on the machine outside the sandbox. A
  process with access to them can mint tokens without the proxy.
- A token lasts up to an hour. A token that the proxy applies to a request
  never reaches the sandbox, so the sandbox cannot keep one.
- Calls that bypass the proxy fail, because the sandbox holds no credential.

## Credential code

The proxy needs a token cache, the reading of ADC files, and the
impersonation call. The `nix-cache-polyfill` program
(`clhodapp/nix-cache-polyfill`), a proxy for Nix binary caches, builds the
same pieces. A repository reads another only through what that repository
publishes, so this proxy starts with a separate copy of that code and moves
to a library crate when `nix-cache-polyfill` publishes one.
